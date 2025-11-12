#!/usr/bin/env python3
# generates demo data for Fineract and registers it with built-in Oracle in vNext
# * deterministic by default (same data every run)
# * use --random for non-deterministic data
# * retries on transient errors (503, connection, timeout, 5xx)
import requests
import random
import hashlib
import json
import datetime
import uuid
import sys
import time
from pathlib import Path
import configparser
import argparse
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Global configuration
# ----------------------------------------------------------------------
_deterministic_mode = True          # default: deterministic
TENANTS = {
    "bluebank": 2,
    "greenbank": 1
}
FIRST_NAMES = [
    "Alice", "Bob", "Charlie", "Diana", "Ethan",
    "Fiona", "George", "Hannah", "Isaac", "Julia",
    "Liam", "Mia", "Noah", "Olivia", "Aiden",
    "Zara", "Elijah", "Sophia", "Lucas", "Amelia",
    "Mason", "Chloe", "Logan", "Ava", "James",
    "Emily", "Benjamin", "Grace", "Jack", "Lily",
    "Henry", "Ella", "Samuel", "Scarlett", "Owen",
    "Aria", "Daniel", "Layla", "Leo", "Sofia",
    "Nathan", "Ruby", "Gabriel", "Isla", "Sebastian",
    "Evie", "Caleb", "Zoe", "Finn", "Nora"
]
LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones",
    "Garcia", "Miller", "Davis", "Rodriguez", "Martinez",
    "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
    "Thomas", "Taylor", "Moore", "Jackson", "Martin",
    "Lee", "Perez", "Thompson", "White", "Harris",
    "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson",
    "Walker", "Young", "Allen", "King", "Wright",
    "Scott", "Torres", "Nguyen", "Hill", "Flores",
    "Green", "Adams", "Nelson", "Baker", "Hall",
    "Rivera", "Campbell", "Mitchell", "Carter", "Roberts"
]

tenant_client_counter = {}

# ----------------------------------------------------------------------
# Global URLs (filled in later)
# ----------------------------------------------------------------------
API_BASE_URL = None
CLIENTS_API_URL = None
SAVINGS_API_URL = None
SAVINGS_PRODUCTS_API_URL = None
INTEROP_PARTIES_API_URL = None
VNEXT_BASE_URL = None

AUTH_HEADER_VALUE = "Basic bWlmb3M6cGFzc3dvcmQ="   # mifos:password
HEADERS = {
    "Fineract-Platform-TenantId": " ",
    "Authorization": AUTH_HEADER_VALUE,
    "Content-Type": "application/json",
    "Accept": "*/*"
}

DATE_FORMAT = "%d %B %Y"
LOCALE = "en"
PRODUCT_CURRENCY_CODE = "USD"
PRODUCT_INTEREST_RATE = 5.0
PRODUCT_SHORTNAME = "savb"
DEFAULT_DEPOSIT_AMOUNT = 5000.0
DEFAULT_PAYMENT_TYPE_ID = 1
PAYLOAD_DATE_FORMAT_LITERAL = "dd MMMM yyyy"

# ----------------------------------------------------------------------
# Helper – resilient API request
# ----------------------------------------------------------------------
def make_api_request(
    method, url, headers, json_data=None, params=None,
    max_retries=5, backoff_factor=2, timeout=30
):
    """Retry on transient errors (5xx, connection, timeout)."""
    print(f"DEBUG make_api_request {method} {url}", file=sys.stderr)
    for attempt in range(max_retries):
        response = None
        try:
            response = requests.request(
                method, url, headers=headers, json=json_data,
                params=params, verify=False, timeout=timeout
            )
            response.raise_for_status()

            # ---- success path ----
            try:
                data = response.json()
                if data is None or (isinstance(data, (dict, list)) and not data):
                    return {}
                return data
            except json.JSONDecodeError:
                print("Warning: 2xx but non-JSON body", file=sys.stderr)
                return {}

        # -------------------------------------------------
        # 1. Connection / timeout → retry
        # -------------------------------------------------
        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout) as e:
            print(f"Transient connection/timeout error: {e} – attempt {attempt+1}/{max_retries}",
                  file=sys.stderr)

        # -------------------------------------------------
        # 2. ANY 5xx (including 503) → retry
        # -------------------------------------------------
        except requests.exceptions.HTTPError as e:
            if e.response is not None and 500 <= e.response.status_code < 600:
                print(f"Transient 5xx error {e.response.status_code} – attempt {attempt+1}/{max_retries}",
                      file=sys.stderr)
            else:
                # 4xx or other non-retryable
                print(f"Non-retryable HTTP error: {e}", file=sys.stderr)
                return None

        # -------------------------------------------------
        # 3. Unexpected → give up
        # -------------------------------------------------
        except Exception as e:
            print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
            return None

        # ---- back-off ----
        if attempt < max_retries - 1:
            sleep = backoff_factor * (2 ** attempt)
            print(f"Retrying in {sleep}s...", file=sys.stderr)
            time.sleep(sleep)

    print("Failed after all retries", file=sys.stderr)
    return None

# ----------------------------------------------------------------------
# Savings product helpers
# ----------------------------------------------------------------------
def get_product_id_by_shortname(headers, shortname):
    data = make_api_request("GET", SAVINGS_PRODUCTS_API_URL, headers)
    if data and isinstance(data, list):
        for p in data:
            if p.get("shortName") == shortname:
                return p.get("id")
    return None

def create_savings_product(headers):
    print(f"Finding/creating product '{PRODUCT_SHORTNAME}'...", file=sys.stderr)
    pid = get_product_id_by_shortname(headers, PRODUCT_SHORTNAME)
    if pid:
        print(f"Using existing product ID {pid}", file=sys.stderr)
        return pid

    payload = {
        "name": PRODUCT_NAME,
        "shortName": PRODUCT_SHORTNAME,
        "currencyCode": PRODUCT_CURRENCY_CODE,
        "digitsAfterDecimal": 2,
        "inMultiplesOf": 1,
        "locale": "en",
        "nominalAnnualInterestRate": PRODUCT_INTEREST_RATE,
        "interestCompoundingPeriodType": 1,
        "interestPostingPeriodType": 4,
        "interestCalculationType": 1,
        "interestCalculationDaysInYearType": 365,
        "accountingRule": 1
    }
    resp = make_api_request("POST", SAVINGS_PRODUCTS_API_URL, headers, json_data=payload)
    if resp:
        pid = resp.get("resourceId")
        if pid:
            print(f"Created product ID {pid}", file=sys.stderr)
            return pid
    print("Failed to create product", file=sys.stderr)
    return None

# ----------------------------------------------------------------------
# Client creation
# ----------------------------------------------------------------------
def create_client(headers, locale, tenant_id):
    count = tenant_client_counter.get(tenant_id, 0)
    tenant_client_counter[tenant_id] = count + 1

    # Name generation – deterministic when _deterministic_mode=True
    global _deterministic_mode
    if _deterministic_mode:
        seed_str = f"{tenant_id}-{count}"
        seed = int(hashlib.sha256(seed_str.encode()).hexdigest(), 16) % (10 ** 8)
        rng = random.Random(seed)
    else:
        rng = random.Random()

    firstname = rng.choice(FIRST_NAMES)
    lastname = rng.choice(LAST_NAMES)

    submitted_date = datetime.datetime.now().strftime(DATE_FORMAT)
    mobile_number = unique_mobile_numbers.pop(0)

    print(f"Creating client {firstname} {lastname} ({mobile_number}) for {tenant_id}", file=sys.stderr)

    payload = {
        "officeId": 1,
        "legalFormId": 1,
        "firstname": firstname,
        "lastname": lastname,
        "submittedOnDate": submitted_date,
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "locale": locale,
        "active": True,
        "activationDate": submitted_date,
        "mobileNo": mobile_number
    }
    resp = make_api_request("POST", CLIENTS_API_URL, headers, json_data=payload)
    if resp:
        cid = resp.get("clientId")
        if cid:
            print(f"Client ID {cid}", file=sys.stderr)
            return cid, mobile_number
    print("Client creation failed", file=sys.stderr)
    return None, None

# ----------------------------------------------------------------------
# Savings account helpers
# ----------------------------------------------------------------------
def create_savings_account(headers, client_id, product_id, locale):
    external_id = str(uuid.uuid4())
    submitted_date = datetime.datetime.now().strftime(DATE_FORMAT)
    payload = {
        "clientId": client_id,
        "productId": product_id,
        "externalId": external_id,
        "locale": locale,
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "submittedOnDate": submitted_date
    }
    resp = make_api_request("POST", SAVINGS_API_URL, headers, json_data=payload)
    if resp:
        sid = resp.get("savingsId")
        if sid:
            print(f"Savings account {sid} (ext {external_id})", file=sys.stderr)
            return sid, external_id
    print("Savings account creation failed", file=sys.stderr)
    return None, None

def approve_savings_account(api_base_url, headers, account_id, date_str):
    url = f"{api_base_url}/savingsaccounts/{account_id}?command=approve"
    body = {"dateFormat": PAYLOAD_DATE_FORMAT_LITERAL, "locale": "en", "approvedOnDate": date_str}
    return make_api_request("POST", url, headers, json_data=body)

def activate_savings_account(api_base_url, headers, account_id, date_str):
    url = f"{api_base_url}/savingsaccounts/{account_id}?command=activate"
    body = {"dateFormat": PAYLOAD_DATE_FORMAT_LITERAL, "locale": "en", "activatedOnDate": date_str}
    return make_api_request("POST", url, headers, json_data=body)

def make_deposit(api_base_url, headers, account_id, amount, date_str, payment_type_id=DEFAULT_PAYMENT_TYPE_ID):
    url = f"{api_base_url}/savingsaccounts/{account_id}/transactions?command=deposit"
    body = {
        "locale": "en",
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "transactionDate": date_str,
        "transactionAmount": amount,
        "paymentTypeId": payment_type_id
    }
    return make_api_request("POST", url, headers, json_data=body)

# ----------------------------------------------------------------------
# Interop / vNext
# ----------------------------------------------------------------------
def register_interop_party(headers, client_id, account_external_id, mobile_number):
    if not mobile_number:
        return False
    url = f"{INTEROP_PARTIES_API_URL}/{mobile_number}"
    payload = {"accountId": account_external_id}
    resp = make_api_request("POST", url, headers, json_data=payload)
    if resp is not None:
        print("Interop party registered", file=sys.stderr)
        return True
    return False

def register_client_with_vnext(headers, tenant_id, mobile_number, currency="USD"):
    url = f"{VNEXT_BASE_URL}{mobile_number}"
    payload = {"fspId": tenant_id, "currency": currency}
    vnext_headers = {
        "fspiop-source": tenant_id,
        "Date": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "Accept": "application/vnd.interoperability.participants+json;version=1.1",
        "Content-Type": "application/vnd.interoperability.participants+json;version=1.1"
    }
    resp = make_api_request("POST", url, vnext_headers, json_data=payload)
    if resp is not None:
        print(f"vNext registration OK for {mobile_number}", file=sys.stderr)
        return True
    return False

# ----------------------------------------------------------------------
# Config / URL setup
# ----------------------------------------------------------------------
def load_config(config_file):
    cfg = configparser.ConfigParser()
    if not cfg.read(config_file):
        print(f"Cannot read config {config_file}", file=sys.stderr)
        sys.exit(1)
    return cfg

def get_gazelle_domain(cfg):
    try:
        return cfg.get('general', 'GAZELLE_DOMAIN')
    except (configparser.NoSectionError, configparser.NoOptionError) as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)

def set_global_urls(domain):
    global API_BASE_URL, CLIENTS_API_URL, SAVINGS_API_URL, SAVINGS_PRODUCTS_API_URL
    global INTEROP_PARTIES_API_URL, VNEXT_BASE_URL
    API_BASE_URL = f"https://mifos.{domain}/fineract-provider/api/v1"
    CLIENTS_API_URL = f"{API_BASE_URL}/clients"
    SAVINGS_API_URL = f"{API_BASE_URL}/savingsaccounts"
    SAVINGS_PRODUCTS_API_URL = f"{API_BASE_URL}/savingsproducts"
    INTEROP_PARTIES_API_URL = f"{API_BASE_URL}/interoperation/parties/MSISDN"
    VNEXT_BASE_URL = f"http://vnextadmin.{domain}/_interop/participants/MSISDN/"

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
if __name__ == "__main__":
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Generate demo data for Mifos + Mojaloop vNext"
    )
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                        help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--random', action='store_true',
                        help='Generate random (non-deterministic) clients')
    args = parser.parse_args()

    # ----- config & URLs -----
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)
    set_global_urls(domain)

    # ----- deterministic / random mode -----
    #global _deterministic_mode
    _deterministic_mode = not args.random
    if _deterministic_mode:
        random.seed(42)
        shuffle_numbers = False
    else:
        random.seed()          # OS entropy / time
        shuffle_numbers = True

    total_clients = sum(TENANTS.values())
    unique_mobile_numbers = [
        f"04{random.randint(10000000, 99999999)}" for _ in range(total_clients)
    ]
    if shuffle_numbers:
        random.shuffle(unique_mobile_numbers)

    # ----- process each tenant -----
    for tenant_id, num_clients in TENANTS.items():
        print(f"\n=== Tenant: {tenant_id} ===", file=sys.stderr)
        HEADERS["Fineract-Platform-TenantId"] = tenant_id
        global PRODUCT_NAME
        PRODUCT_NAME = f"{tenant_id}-savings"

        # product
        product_id = create_savings_product(HEADERS)
        if not product_id:
            print(f"Skipping tenant {tenant_id} – no product", file=sys.stderr)
            continue

        process_date = datetime.datetime.now().strftime(DATE_FORMAT)

        for i in range(1, num_clients + 1):
            print(f"\n--- Client {i}/{num_clients} for {tenant_id} ---", file=sys.stderr)

            # client
            client_id, mobile = create_client(HEADERS, LOCALE, tenant_id)
            if not client_id:
                continue

            # savings account
            acct_id, ext_id = create_savings_account(HEADERS, client_id, product_id, LOCALE)
            if not acct_id:
                continue

            # approve
            if not approve_savings_account(API_BASE_URL, HEADERS, acct_id, process_date):
                continue

            # activate
            if not activate_savings_account(API_BASE_URL, HEADERS, acct_id, process_date):
                continue

            # deposit
            if not make_deposit(API_BASE_URL, HEADERS, acct_id, DEFAULT_DEPOSIT_AMOUNT,
                                process_date, DEFAULT_PAYMENT_TYPE_ID):
                continue

            # interop & vNext
            register_interop_party(HEADERS, client_id, ext_id, mobile)
            register_client_with_vnext(HEADERS, tenant_id, mobile)

            print(f"--- Finished client {i} ---", file=sys.stderr)

        print(f"=== Finished tenant {tenant_id} ===\n", file=sys.stderr)

    print("All tenants processed.", file=sys.stderr)