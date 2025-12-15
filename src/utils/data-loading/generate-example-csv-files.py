#!/usr/bin/env python3
"""
Generate example bulk payment CSV files for Payment Hub testing.
Creates CSV files with test data from Mifos clients.
"""

import sys
import csv
import uuid
import argparse
import configparser
from pathlib import Path

# ----------------------------------------------------------------------
# Hard-coded Test Data (fallback if Mifos is not accessible)
# ----------------------------------------------------------------------
# Payer: Ava Brown (greenbank account 1)
DEFAULT_PAYER_MSISDN = "0413356886"

# Payees
DEFAULT_PAYEES = [
    {
        "msisdn": "0495822412",
        "name": "James Ramirez",
        "account": "1",
        "amounts": [10.00, 16.00]
    },
    {
        "msisdn": "0424942603",
        "name": "Caleb Harris",
        "account": "2",
        "amounts": [15.00, 20.00]
    }
]

# ----------------------------------------------------------------------
# Utility Functions
# ----------------------------------------------------------------------
def load_config(config_path):
    """Load configuration from config.ini file."""
    config = configparser.ConfigParser()
    config.read(config_path)
    return config

def get_gazelle_domain(config):
    """Extract Gazelle domain from config."""
    try:
        return config['gazelle']['domain']
    except KeyError:
        return 'mifos.gazelle.localhost'

# ----------------------------------------------------------------------
# CSV Generation
# ----------------------------------------------------------------------
def generate_csv_data(mode='closedloop', payer_msisdn=None, payees=None):
    """
    Generate CSV test data for bulk transactions.

    Args:
        mode: 'closedloop' or 'mojaloop'
        payer_msisdn: Payer phone number (defaults to DEFAULT_PAYER_MSISDN)
        payees: List of payee dictionaries (defaults to DEFAULT_PAYEES)

    Returns:
        List of transaction dictionaries
    """
    if payer_msisdn is None:
        payer_msisdn = DEFAULT_PAYER_MSISDN
    if payees is None:
        payees = DEFAULT_PAYEES

    transactions = []
    txn_id = 0

    for payee in payees:
        for amount in payee['amounts']:
            transaction = {
                'id': txn_id,
                'request_id': str(uuid.uuid4()),
                'payment_mode': mode,
                'payer_identifier_type': 'MSISDN',
                'payer_identifier': payer_msisdn,
                'payee_identifier_type': 'MSISDN',
                'payee_identifier': payee['msisdn'],
                'amount': f"{amount:.2f}",
                'currency': 'USD',
                'note': f"Payment to {payee['name']}",
                'account_number': payee['account']
            }

            transactions.append(transaction)
            txn_id += 1

    return transactions

def generate_govstack_csv_data(payees=None):
    """
    Generate CSV test data for GovStack mode (no payer columns).

    Args:
        payees: List of payee dictionaries (defaults to DEFAULT_PAYEES)

    Returns:
        List of transaction dictionaries
    """
    if payees is None:
        payees = DEFAULT_PAYEES

    transactions = []
    txn_id = 0

    for payee in payees:
        for amount in payee['amounts']:
            transaction = {
                'id': txn_id,
                'request_id': str(uuid.uuid4()),
                'payment_mode': 'closedloop',  # GovStack uses closedloop
                'payee_identifier_type': 'MSISDN',
                'payee_identifier': payee['msisdn'],
                'amount': f"{amount:.2f}",
                'currency': 'USD',
                'note': f"Payment to {payee['name']}",
                'account_number': payee['account']
            }

            transactions.append(transaction)
            txn_id += 1

    return transactions

def write_csv_file(csv_path, transactions, govstack_mode=False):
    """Write transactions to CSV file."""
    # Define column order based on mode
    if govstack_mode:
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

    with open(csv_path, 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for txn in transactions:
            writer.writerow(txn)

    return csv_path

def generate_csv_files(output_dir=None, payer_msisdn=None, payees=None):
    """
    Generate all example CSV files.

    Args:
        output_dir: Directory to write CSV files (defaults to script directory)
        payer_msisdn: Payer phone number
        payees: List of payee dictionaries

    Returns:
        Dictionary of generated file paths
    """
    if output_dir is None:
        output_dir = Path(__file__).parent
    else:
        output_dir = Path(output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)

    files = {}

    # Generate closedloop CSV
    closedloop_data = generate_csv_data('closedloop', payer_msisdn, payees)
    closedloop_path = output_dir / 'bulk-gazelle-closedloop-4.csv'
    write_csv_file(closedloop_path, closedloop_data, govstack_mode=False)
    files['closedloop'] = closedloop_path
    print(f"✓ Generated {closedloop_path}", file=sys.stderr)

    # Generate mojaloop CSV
    mojaloop_data = generate_csv_data('mojaloop', payer_msisdn, payees)
    mojaloop_path = output_dir / 'bulk-gazelle-mojaloop-4.csv'
    write_csv_file(mojaloop_path, mojaloop_data, govstack_mode=False)
    files['mojaloop'] = mojaloop_path
    print(f"✓ Generated {mojaloop_path}", file=sys.stderr)

    # Generate GovStack CSV (no payer columns)
    govstack_data = generate_govstack_csv_data(payees)
    govstack_path = output_dir / 'bulk-gazelle-govstack-4.csv'
    write_csv_file(govstack_path, govstack_data, govstack_mode=True)
    files['govstack'] = govstack_path
    print(f"✓ Generated {govstack_path}", file=sys.stderr)

    return files

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    # Setup argument parser
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"
    default_output = script_path.parent

    parser = argparse.ArgumentParser(
        description="Generate example bulk payment CSV files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate all CSV files with defaults
  ./generate-example-csv-files.py

  # Generate with custom config
  ./generate-example-csv-files.py --config ~/myconfig.ini

  # Generate to specific directory
  ./generate-example-csv-files.py --output-dir /tmp/csv-files

  # Generate specific mode only
  ./generate-example-csv-files.py --mode closedloop

Generated files:
  - bulk-gazelle-closedloop-4.csv (Non-GovStack, closedloop mode)
  - bulk-gazelle-mojaloop-4.csv (Non-GovStack, mojaloop mode)
  - bulk-gazelle-govstack-4.csv (GovStack mode, no payer columns)
        """
    )

    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--output-dir', '-o', type=Path, default=default_output,
                       help=f'Output directory for CSV files (default: {default_output})')
    parser.add_argument('--mode', '-m', choices=['closedloop', 'mojaloop', 'govstack', 'all'],
                       default='all',
                       help='Generate specific mode only, or all (default: all)')
    parser.add_argument('--payer-msisdn', '-p', type=str, default=DEFAULT_PAYER_MSISDN,
                       help=f'Payer phone number (default: {DEFAULT_PAYER_MSISDN})')

    args = parser.parse_args()

    print("=== CSV File Generation ===\n", file=sys.stderr)
    print(f"Output directory: {args.output_dir}\n", file=sys.stderr)

    # Prepare output directory
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Generate requested CSV files
    if args.mode == 'all':
        files = generate_csv_files(args.output_dir, args.payer_msisdn, DEFAULT_PAYEES)
        print(f"\n✓ Generated {len(files)} CSV files", file=sys.stderr)
    else:
        # Generate single mode
        if args.mode == 'govstack':
            data = generate_govstack_csv_data(DEFAULT_PAYEES)
            csv_path = args.output_dir / f'bulk-gazelle-{args.mode}-4.csv'
            write_csv_file(csv_path, data, govstack_mode=True)
        else:
            data = generate_csv_data(args.mode, args.payer_msisdn, DEFAULT_PAYEES)
            csv_path = args.output_dir / f'bulk-gazelle-{args.mode}-4.csv'
            write_csv_file(csv_path, data, govstack_mode=False)

        print(f"✓ Generated {csv_path}", file=sys.stderr)

    print("\n============================================================", file=sys.stderr)
    print(f"CSV files created with {len(DEFAULT_PAYEES) * len(DEFAULT_PAYEES[0]['amounts'])} transactions:", file=sys.stderr)
    print(f"  Payer: {args.payer_msisdn} (greenbank)", file=sys.stderr)
    for payee in DEFAULT_PAYEES:
        print(f"  Payee: {payee['name']} ({payee['msisdn']}) - account {payee['account']}", file=sys.stderr)
    print("============================================================\n", file=sys.stderr)

if __name__ == "__main__":
    main()
