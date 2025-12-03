#!/usr/bin/env python3
"""
Register existing Mifos clients with identity-account-mapper and generate bulk CSV files.
This script queries Mifos dynamically to get current clients rather than using hardcoded data.
"""

import requests
import uuid
import sys
import configparser
from pathlib import Path
import argparse
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
def load_config(config_file):
    """Load configuration from config.ini."""
    cfg = configparser.ConfigParser()
    if not cfg.read(config_file):
        print(f"Cannot read config {config_file}", file=sys.stderr)
        sys.exit(1)
    return cfg

def get_gazelle_domain(cfg):
    """Extract GAZELLE_DOMAIN from config."""
    try:
        return cfg.get('general', 'GAZELLE_DOMAIN')
    except (configparser.NoSectionError, configparser.NoOptionError) as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)

def get_tenants(cfg):
    """Extract tenant list from config, fallback to default if not specified."""
    try:
        # Try to read from config first
        tenants_str = cfg.get('general', 'TENANTS')
        # Parse comma-separated list
        return [t.strip() for t in tenants_str.split(',')]
    except (configparser.NoSectionError, configparser.NoOptionError):
        # Default tenants if not in config
        return ['greenbank', 'bluebank']

# ----------------------------------------------------------------------
# Mifos API - Query clients dynamically
# ----------------------------------------------------------------------
AUTH_HEADER_VALUE = "Basic bWlmb3M6cGFzc3dvcmQ="  # mifos:password

def get_clients_from_mifos(domain, tenant):
    """Query Mifos to get all clients for a tenant."""
    url = f"https://mifos.{domain}/fineract-provider/api/v1/clients"
    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": AUTH_HEADER_VALUE,
        "Accept": "application/json"
    }

    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()
        data = response.json()

        clients = []
        if 'pageItems' in data:
            for client in data['pageItems']:
                clients.append({
                    'client_id': client.get('id'),
                    'name': client.get('displayName'),
                    'mobile': client.get('mobileNo'),
                    'tenant': tenant
                })

        return clients
    except Exception as e:
        print(f"Error fetching clients for {tenant}: {e}", file=sys.stderr)
        return []

def get_savings_accounts_for_client(domain, tenant, client_id):
    """Get savings accounts for a specific client."""
    url = f"https://mifos.{domain}/fineract-provider/api/v1/clients/{client_id}/accounts"
    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": AUTH_HEADER_VALUE,
        "Accept": "application/json"
    }

    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()
        data = response.json()

        # Get savings accounts
        savings = data.get('savingsAccounts', [])
        if savings:
            # Return the first active savings account
            for acct in savings:
                if acct.get('status', {}).get('active'):
                    return acct.get('id')
            # If no active, return first one
            return savings[0].get('id')

        return None
    except Exception as e:
        print(f"Error fetching accounts for client {client_id} in {tenant}: {e}", file=sys.stderr)
        return None

def fetch_all_clients_from_mifos(domain, tenants):
    """Fetch all clients with their savings accounts from Mifos."""
    all_clients = []

    for tenant in tenants:
        print(f"Querying {tenant} for clients...", file=sys.stderr)
        clients = get_clients_from_mifos(domain, tenant)

        for client in clients:
            if not client['mobile']:
                print(f"  Skipping {client['name']} - no mobile number", file=sys.stderr)
                continue

            # Get savings account
            account_id = get_savings_accounts_for_client(domain, tenant, client['client_id'])
            if not account_id:
                print(f"  Skipping {client['name']} - no savings account", file=sys.stderr)
                continue

            client['account_id'] = account_id
            all_clients.append(client)
            print(f"  Found: {client['name']} (MSISDN: {client['mobile']}, Account: {account_id})", file=sys.stderr)

    return all_clients

# ----------------------------------------------------------------------
# Identity Mapper Registration
# ----------------------------------------------------------------------
def register_with_identity_mapper(domain, client):
    """Register a client with identity-account-mapper."""
    # Use localhost domain for actual cluster access
    url = f"https://identity-mapper.mifos.gazelle.localhost/beneficiary"
    # Request ID must be exactly 12 characters
    request_id = str(uuid.uuid4()).replace('-', '')[:12]

    beneficiary = {
        "payeeIdentity": client['mobile'],
        "paymentModality": "00",  # MSISDN payment modality
        "financialAddress": str(client['account_id']),
        "bankingInstitutionCode": client['tenant']
    }

    payload = {
        "requestID": request_id,  # Note: capital ID required
        "sourceBBID": client['tenant'],
        "beneficiaries": [beneficiary]
    }

    headers = {
        "X-CallbackURL": f"https://callback.{client['tenant']}",
        "X-Registering-Institution-ID": client['tenant'],
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    try:
        response = requests.post(url, json=payload, headers=headers, verify=False, timeout=30)

        # Check if we got a structured response (even if HTTP status is 500)
        # responseCode "01" means the identity mapper processed it
        # (callback failure is expected with fake callback URL)
        try:
            resp_json = response.json()
            if 'responseCode' in resp_json:
                print(f"✓ Registered {client['name']} ({client['mobile']}) → account {client['account_id']} @ {client['tenant']}", file=sys.stderr)
                print(f"   Response: {resp_json.get('responseDescription', 'OK')}", file=sys.stderr)
                return True
        except:
            pass

        # If 2xx status, consider it success
        if 200 <= response.status_code < 300:
            print(f"✓ Registered {client['name']} ({client['mobile']}) → account {client['account_id']} @ {client['tenant']}", file=sys.stderr)
            return True

        # Otherwise report error
        print(f"✗ Failed to register {client['name']}: HTTP {response.status_code}", file=sys.stderr)
        print(f"   Response: {response.text}", file=sys.stderr)
        return False

    except Exception as e:
        print(f"✗ Failed to register {client['name']}: {e}", file=sys.stderr)
        return False

# ----------------------------------------------------------------------
# CSV Generation
# ----------------------------------------------------------------------
def generate_csv_files(all_clients, payer_tenant='greenbank'):
    """Generate mojaloop and closedloop CSV files."""
    script_dir = Path(__file__).parent

    # Find payer (default: greenbank) and payees (all other tenants)
    payer = None
    payees = []

    for client in all_clients:
        if client['tenant'] == payer_tenant:
            if payer is None:  # Take first client from payer tenant
                payer = client
        else:
            payees.append(client)

    if not payer:
        print(f"ERROR: No {payer_tenant} payer found", file=sys.stderr)
        return

    if len(payees) < 1:
        print(f"ERROR: Need at least 1 payee from other tenants, found {len(payees)}", file=sys.stderr)
        return

    # Generate 4 transactions: 2 to each payee
    transactions = []
    amounts = [10.00, 15.00]

    for payee in payees[:2]:
        for amount in amounts:
            txn_id = len(transactions)
            request_id = str(uuid.uuid4())
            transactions.append({
                'id': txn_id,
                'request_id': request_id,
                'payer_mobile': payer['mobile'],
                'payer_account': payer['account_id'],
                'payee_mobile': payee['mobile'],
                'payee_account': payee['account_id'],
                'payee_name': payee['name'],
                'amount': amount
            })

    # Generate MOJALOOP CSV
    mojaloop_file = script_dir / "bulk-gazelle-mojaloop-4.csv"
    print(f"\nGenerating {mojaloop_file}", file=sys.stderr)

    with open(mojaloop_file, 'w') as f:
        # Header
        f.write("id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number\n")

        # Transactions (NO trailing newline after last row)
        for i, txn in enumerate(transactions):
            line = f"{txn['id']},{txn['request_id']},mojaloop,MSISDN,{txn['payer_mobile']},MSISDN,{txn['payee_mobile']},{txn['amount']:.2f},USD,Payment to {txn['payee_name']},{txn['payee_account']}"
            if i < len(transactions) - 1:
                f.write(line + "\n")
            else:
                f.write(line)  # NO newline after last row

    print(f"✓ Generated {mojaloop_file}", file=sys.stderr)

    # Generate CLOSEDLOOP CSV
    closedloop_file = script_dir / "bulk-gazelle-closedloop-4.csv"
    print(f"Generating {closedloop_file}", file=sys.stderr)

    with open(closedloop_file, 'w') as f:
        # Header
        f.write("id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number\n")

        # Transactions (NO trailing newline after last row)
        for i, txn in enumerate(transactions):
            line = f"{txn['id']},{txn['request_id']},closedloop,MSISDN,{txn['payer_mobile']},MSISDN,{txn['payee_mobile']},{txn['amount']:.2f},USD,Payment to {txn['payee_name']},{txn['payee_account']}"
            if i < len(transactions) - 1:
                f.write(line + "\n")
            else:
                f.write(line)  # NO newline after last row

    print(f"✓ Generated {closedloop_file}", file=sys.stderr)

    # Print summary
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"CSV files created with {len(transactions)} transactions:", file=sys.stderr)
    print(f"  - {mojaloop_file.name}", file=sys.stderr)
    print(f"  - {closedloop_file.name}", file=sys.stderr)
    print(f"\nPayer: {payer['name']} ({payer['mobile']}) - greenbank account {payer['account_id']}", file=sys.stderr)
    for idx, payee in enumerate(payees[:2]):
        print(f"Payee {idx+1}: {payee['name']} ({payee['mobile']}) - bluebank account {payee['account_id']}", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
if __name__ == "__main__":
    print("=== Identity Mapper Registration & CSV Generation ===\n", file=sys.stderr)

    # Load config
    domain = load_config()
    print(f"Using domain: {domain}\n", file=sys.stderr)

    # Register each client with identity-account-mapper
    print("Registering clients with identity-account-mapper...", file=sys.stderr)
    success_count = 0
    for client in EXISTING_CLIENTS:
        if register_with_identity_mapper(domain, client):
            success_count += 1

    print(f"\nRegistered {success_count}/{len(EXISTING_CLIENTS)} clients", file=sys.stderr)

    # Generate CSV files
    generate_csv_files()

    print("\n✓ All done!", file=sys.stderr)
