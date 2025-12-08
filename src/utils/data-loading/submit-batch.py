#!/usr/bin/env python3
"""
Submit batch CSV file to Payment Hub bulk-processor.
Generates CSV files from hard-coded test data and submits to bulk-processor endpoint.
"""

import requests
import sys
import configparser
import csv
import json
import uuid
from pathlib import Path
import argparse
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Hard-coded Test Data
# ----------------------------------------------------------------------
# Payer: Ava Brown (greenbank account 1)
PAYER_MSISDN = "0413356886"

# Payees
PAYEES = [
    {
        "msisdn": "0495822412",
        "name": "James Ramirez",
        "account": "1",
        "amounts": [10.00, 15.00]
    },
    {
        "msisdn": "0424942603",
        "name": "Caleb Harris",
        "account": "2",
        "amounts": [10.00, 15.00]
    }
]

# Default secret key
DEFAULT_SECRET_KEY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC07fxdEQlsvWvggBgrork401cdyZ9MqV6FF/RgX6+Om23gP/rME5sE5//OoG61KU3dEj9phcHH845TuyNEyc4Vhqxe1gzl4VIZkOj+/2qxYvCsP1Sv3twTs+fDfFv5NA1ZXqiswTlgjR2Lpf1tevFQEOzB9WYvH/Bu9kgr2AlHMPV6+b7gcJij/7W1hndiCk2ahbi7oXjjODF4yEU9yNAhopibe4zzMX+FO4eFYpUmrjS5wvv6aAanfoeIMTwhF81Gj9V3rHf4UsD3VEx773q7GPuXlZSLyiNrUCdvxITh+dW8Y9ICuCTy3bFbp1/HzoPdzkkUlzPNKLlLiV2w4EcxAgMBAAECggEAMjqHfwbFyQxlMHQfQa3xIdd6LejVcqDqfqSB0Wd/A2YfAMyCQbmHpbsKh0B+u4h191OjixX5EBuLfa9MQUKNFejHXaSq+/6rnjFenbwm0IwZKJiEWDbUfhvJ0blqhypuMktXJG6YETfb5fL1AjnJWGL6d3Y7IgYJ56QzsQhOuxZidSqw468xc4sIF0CoTeJdrSC2yDCVuVlLNifm/2SXBJD8mgc1WCz0rkJhvvpW4k5G9rRSkS5f0013ZNfsfiDXoqiKkafoYNEbk7TZQNInqSuONm/UECn5GLm6IXdXSGfm1O2Lt0Kk7uxW/3W00mIPeZD+hiOObheRm/2HoOEKiQKBgQDreVFQihXAEDviIB2s6fphvPcMw/IonE8tX565i3303ubQMDIyZmsi3apN5pqSjm1TKq1KIgY2D4vYTu6vO5x9MhEO2CCZWNwC+awrIYa32FwiT8D8eZ9g+DJ4/IwXyz1fG38RCz/eIsJ0NsS9z8RKBIbfMmM+WnXRez3Fq+cbRwKBgQDEs35qXThbbFUYo1QkO0vIo85iczu9NllRxo1nAqQkfu1oTYQQobxcGk/aZk0B02r9kt2eob8zfG+X3LadIhQ0/LalnGNKI9jWLkdW4dxi7xMU99MYc3NRXmR49xGxgOVkLzKyGMisUvkTnE5v/S1nhu5uFr3JPkWcCScLOTjVxwKBgHNWsDq3+GFkUkC3pHF/BhJ7wbLyA5pavfmmnZOavO6FhB8zjFLdkdq5IuMXcl0ZAHm9LLZkJhCy2rfwKb+RflxgerR/rrAOM24Np4RU3q0MgEyaLhg85pFT4T0bzu8UsRH14O6TSQxgkEjmTsX+j9IFl56aCryPCKi8Kgy53/CfAoGAdV2kUFLPDb3WCJ1r1zKKRW1398ZKHtwO73xJYu1wg1Y40cNuyX23pj0M6IOh7zT24dZ/5ecc7tuQukw3qgprhDJFyQtHMzWwbBuw9WZO2blM6XX1vuEkLajkykihhggi12RSG3IuSqQ3ejwJkUi/jsYz/fwTwcAmSLQtV8UM5IECgYEAh4h1EkMx3NXzVFmLsb4QLMXw8+Rnn9oG+NGObldQ+nmknUPu7iz5kl9lTJy+jWtqHlHL8ZtV1cZZSZnFxX5WQH5/lcz/UD+GqWoSlWuTU34PPTJqLKSYgkoOJQDEZVMVphLySS9tuo+K/h10lRS1r9KDm3RZASa1JnnWopBZIz4="

# ----------------------------------------------------------------------
# CSV Generation
# ----------------------------------------------------------------------
def generate_csv_data(mode='closedloop'):
    """
    Generate CSV test data for bulk transactions.

    Args:
        mode: 'closedloop', 'mojaloop', or 'govstack'

    Returns:
        List of transaction dictionaries
    """
    transactions = []
    txn_id = 0

    for payee in PAYEES:
        for amount in payee['amounts']:
            transaction = {
                'id': txn_id,
                'request_id': str(uuid.uuid4()),
                'payment_mode': mode if mode != 'govstack' else 'closedloop',
                'payee_identifier_type': 'MSISDN',
                'payee_identifier': payee['msisdn'],
                'amount': f"{amount:.2f}",
                'currency': 'USD',
                'note': f"Payment to {payee['name']}",
                'account_number': payee['account']
            }

            # Add payer info for non-govstack modes
            if mode != 'govstack':
                transaction['payer_identifier_type'] = 'MSISDN'
                transaction['payer_identifier'] = PAYER_MSISDN

            transactions.append(transaction)
            txn_id += 1

    return transactions

def write_csv_file(csv_path, transactions, mode='closedloop'):
    """Write transactions to CSV file."""
    # Define column order based on mode
    if mode == 'govstack':
        fieldnames = [
            'id', 'request_id', 'payment_mode',
            'payee_identifier_type', 'payee_identifier',
            'amount', 'currency', 'note', 'account_number'
        ]
    else:
        fieldnames = [
            'id', 'request_id', 'payment_mode',
            'payer_identifier_type', 'payer_identifier',
            'payee_identifier_type', 'payee_identifier',
            'amount', 'currency', 'note', 'account_number'
        ]

    with open(csv_path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(transactions)

    print(f"✓ Generated: {csv_path}", file=sys.stderr)
    print(f"  Transactions: {len(transactions)}", file=sys.stderr)
    print(f"  Mode: {mode}", file=sys.stderr)
    return csv_path

def generate_all_csvs():
    """Generate all CSV variants."""
    script_dir = Path(__file__).parent

    print("\n" + "="*80, file=sys.stderr)
    print("GENERATING CSV FILES", file=sys.stderr)
    print("="*80, file=sys.stderr)

    csvs = {}

    # Generate closedloop CSV
    closedloop_data = generate_csv_data('closedloop')
    csvs['closedloop'] = write_csv_file(
        script_dir / 'bulk-gazelle-closedloop-4.csv',
        closedloop_data,
        'closedloop'
    )

    # Generate mojaloop CSV
    mojaloop_data = generate_csv_data('mojaloop')
    csvs['mojaloop'] = write_csv_file(
        script_dir / 'bulk-gazelle-mojaloop-4.csv',
        mojaloop_data,
        'mojaloop'
    )

    # Generate govstack CSV (minimal - no payer columns)
    govstack_data = generate_csv_data('govstack')
    csvs['govstack'] = write_csv_file(
        script_dir / 'bulk-gazelle-govstack-4.csv',
        govstack_data,
        'govstack'
    )

    print("="*80 + "\n", file=sys.stderr)
    return csvs

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

# ----------------------------------------------------------------------
# Signature Generation
# ----------------------------------------------------------------------
def generate_signature(domain, csv_file_path, private_key, tenant='greenbank', correlation_id=None):
    """Generate X-Signature using ops service."""
    url = f"https://ops.{domain}/api/v1/util/x-signature"

    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    headers = {
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "privateKey": private_key
    }

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (csv_file_path.name, f, 'text/csv')}

            print(f"Generating signature...", file=sys.stderr)

            response = requests.post(
                url,
                headers=headers,
                files=files,
                verify=False,
                timeout=30
            )

            if response.status_code != 200:
                print(f"Error from ops service: {response.status_code}", file=sys.stderr)
                print(f"Response: {response.text}", file=sys.stderr)
                response.raise_for_status()

            signature = response.text.strip()
            print(f"✓ Signature generated", file=sys.stderr)
            return signature, correlation_id

    except Exception as e:
        print(f"Error generating signature: {e}", file=sys.stderr)
        raise

# ----------------------------------------------------------------------
# Batch Submission
# ----------------------------------------------------------------------
def submit_batch(domain, csv_file_path, signature, tenant='greenbank',
                correlation_id=None, registering_institution=None, program_id=None):
    """Submit batch to bulk-processor endpoint."""
    url = f"https://bulk-processor.{domain}/batchtransactions"

    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    headers = {
        "X-Signature": signature,
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "type": "csv",
        "filename": csv_file_path.name,
        "X-CallbackURL": f"http://ph-ee-connector-mock-payment-schema:8080/batches/{correlation_id}/callback",
        "Purpose": "Batch payment"
    }

    # Add GovStack headers if provided
    if registering_institution:
        headers['X-Registering-Institution-ID'] = registering_institution
    if program_id:
        headers['X-Program-ID'] = program_id

    print(f"\n" + "="*80, file=sys.stderr)
    print(f"SUBMITTING BATCH", file=sys.stderr)
    print("="*80, file=sys.stderr)
    print(f"URL: {url}", file=sys.stderr)
    print(f"File: {csv_file_path.name}", file=sys.stderr)
    print(f"Tenant: {tenant}", file=sys.stderr)
    if registering_institution:
        print(f"GovStack Institution: {registering_institution}", file=sys.stderr)
    if program_id:
        print(f"GovStack Program: {program_id}", file=sys.stderr)
    print("="*80, file=sys.stderr)

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (csv_file_path.name, f, 'text/csv')}

            response = requests.post(
                url,
                headers=headers,
                files=files,
                verify=False,
                timeout=60
            )

        print(f"\nResponse Status: {response.status_code}", file=sys.stderr)

        try:
            response_data = response.json()
            print(f"\nResponse Body:", file=sys.stderr)
            print(json.dumps(response_data, indent=2), file=sys.stderr)

            if response.status_code >= 200 and response.status_code < 300:
                return response_data
            else:
                return None
        except:
            print(f"\nResponse Body (text):", file=sys.stderr)
            print(response.text, file=sys.stderr)

            if response.status_code >= 200 and response.status_code < 300:
                return {"status": "success"}
            else:
                return None

    except Exception as e:
        print(f"\nError submitting batch: {e}", file=sys.stderr)
        return None

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Generate and submit batch CSV files to Payment Hub bulk-processor",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate all CSV files only (no submission)
  ./submit-batch.py --generate-only

  # Generate and submit closedloop batch
  ./submit-batch.py --mode closedloop

  # Generate and submit mojaloop batch
  ./submit-batch.py --mode mojaloop

  # Generate and submit GovStack batch
  ./submit-batch.py --mode govstack --institution greenbank --program SocialWelfare

  # Submit existing CSV file
  ./submit-batch.py --csv-file bulk-gazelle-closedloop-4.csv
        """
    )

    parser.add_argument('--mode', '-m', type=str,
                       choices=['closedloop', 'mojaloop', 'govstack'],
                       help='Payment mode (auto-generates CSV)')
    parser.add_argument('--csv-file', '-f', type=Path,
                       help='Explicit CSV file to submit (skips generation)')
    parser.add_argument('--generate-only', '-g', action='store_true',
                       help='Generate CSV files but do not submit')
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--tenant', '-t', type=str, default='greenbank',
                       help='Tenant ID (default: greenbank)')
    parser.add_argument('--institution', '-i', type=str,
                       help='Registering institution ID for GovStack mode')
    parser.add_argument('--program', '-p', type=str,
                       help='Program ID for GovStack mode')
    parser.add_argument('--secret-key', '-k', type=str, default=DEFAULT_SECRET_KEY,
                       help='Secret key for signing (default: built-in key)')

    args = parser.parse_args()

    # Load config
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)

    print("="*80)
    print(f"PAYMENT HUB BATCH TOOL - {domain}")
    print("="*80)

    # Determine CSV file to use
    csv_file_to_submit = None

    if args.csv_file:
        # Explicit CSV file provided
        if not args.csv_file.exists():
            print(f"Error: CSV file not found: {args.csv_file}", file=sys.stderr)
            sys.exit(1)
        csv_file_to_submit = args.csv_file
        print(f"\nUsing provided CSV: {csv_file_to_submit}", file=sys.stderr)

    elif args.mode:
        # Generate CSV for specified mode
        csvs = generate_all_csvs()
        csv_file_to_submit = csvs[args.mode]

        # Set GovStack defaults if mode is govstack
        if args.mode == 'govstack':
            if not args.institution:
                args.institution = 'greenbank'
                print(f"GovStack mode: using default institution 'greenbank'", file=sys.stderr)
            if not args.program:
                args.program = 'SocialWelfare'
                print(f"GovStack mode: using default program 'SocialWelfare'", file=sys.stderr)

    else:
        # Generate all CSVs
        generate_all_csvs()

        if not args.generate_only:
            print("\nNo mode specified. Use --mode to submit, or --generate-only to just generate CSVs.", file=sys.stderr)
            print("\nAvailable modes: closedloop, mojaloop, govstack", file=sys.stderr)
            sys.exit(0)
        else:
            print("\n✓ CSV generation complete!", file=sys.stderr)
            sys.exit(0)

    # Exit if generate-only mode
    if args.generate_only:
        print("\n✓ CSV generation complete! (not submitting)", file=sys.stderr)
        sys.exit(0)

    # Submit the CSV
    if csv_file_to_submit:
        correlation_id = str(uuid.uuid4())

        # Generate signature
        signature, correlation_id = generate_signature(
            domain,
            csv_file_to_submit,
            args.secret_key,
            tenant=args.tenant,
            correlation_id=correlation_id
        )

        # Submit batch
        result = submit_batch(
            domain,
            csv_file_to_submit,
            signature,
            tenant=args.tenant,
            correlation_id=correlation_id,
            registering_institution=args.institution,
            program_id=args.program
        )

        if result:
            print("\n✓ Batch submitted successfully!", file=sys.stderr)
            sys.exit(0)
        else:
            print("\n✗ Batch submission failed", file=sys.stderr)
            sys.exit(1)

if __name__ == "__main__":
    main()
