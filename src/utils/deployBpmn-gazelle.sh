#!/bin/bash
# Define variables for the charts
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
config_dir="$( cd $(dirname "$SCRIPT_DIR")/../config ; pwd )"
default_config_ini="$config_dir/config.ini"
config_ini="$default_config_ini"  # Will be overridden if -c is specified
BPMN_DIR="$( cd $(dirname "$SCRIPT_DIR")/../orchestration/ ; pwd )"
DEBUG=false
TENANT="greenbank"  # Default tenant TODO does this actually do anything 

deploy() {
    local file="$1"
    local cmd="curl --insecure --location --request POST $HOST \
        --header 'Platform-TenantId:$TENANT' \
        --form 'file=@\"$file\"' \
        -s -o /dev/null -w '%{http_code}'"
    
    if [ "$DEBUG" = true ]; then
        echo "Executing: $cmd"
        http_code=$(eval $cmd)
        exit_code=$?
        echo "HTTP Code: $http_code"
        echo "Exit code: $exit_code"
    else
        http_code=$(eval $cmd)
        exit_code=$?
        if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
            echo "File: $file - Upload successful"
        else
            echo "File: $file - Upload failed (HTTP Code: $http_code)"
        fi
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -c <config> Specify the config.ini file to use (default: $default_config_ini).
  -f <file>   Specify a single file to upload.
  -t <tenant> Specify the tenant name (default: greenbank).
  -d          Enable debug mode for detailed output.
  -h          Show this help message.

Description:
  This script uploads BPMN files to a Zeebe instance. If no file is specified,
  it will upload all BPMN files from predefined locations.

Examples:
  $(basename "$0") -c /path/to/custom.ini -f myprocess.bpmn
  $(basename "$0") -c /path/to/custom.ini -t mytenant
  $(basename "$0") -f myprocess.bpmn
EOF
    exit 0
}

# Parse command line arguments
while getopts ":c:f:t:dh" opt; do
    case $opt in
        c)
            config_ini="$OPTARG"
            if [ ! -f "$config_ini" ]; then
                echo "Error: Config file '$config_ini' not found." >&2
                exit 1
            fi
            ;;
        f)
            SINGLE_FILE="$OPTARG"
            ;;
        t)
            TENANT="$OPTARG"
            ;;
        d)
            DEBUG=true
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done

# Extract domain from the config file (after -c has been processed)
domain=$(grep GAZELLE_DOMAIN "$config_ini" | cut -d '=' -f2 | tr -d " " )

if [ -z "$domain" ]; then
    echo "Error: GAZELLE_DOMAIN not found in $config_ini" >&2
    exit 1
fi

HOST="https://zeebeops.$domain/zeebe/upload"
echo "Using config file: $config_ini"
echo "Using domain: $domain"
echo "Using Endpoint: $HOST"

# If a single file is specified, upload only that file
if [ -n "$SINGLE_FILE" ]; then
    if [ -f "$SINGLE_FILE" ]; then
        deploy "$SINGLE_FILE"
    else
        echo "Error: File '$SINGLE_FILE' not found."
        exit 1
    fi
else
    # Deploy files from predefined locations
    echo "Deploying BPMN files from $BPMN_DIR/feel/"
    for location in "$BPMN_DIR/feel/"*.bpmn; do
        echo "Deploying BPMN file: $location"
        [ -e "$location" ] || continue  # Skip if no files match the glob
        deploy "$location"
        sleep 2
    done
fi