#!/usr/bin/env bash

########################################################################
# GLOBAL VARS
# these are not user configurables - for internal script use only
########################################################################
BASE_DIR=$( cd $(dirname "$0") ; pwd )
APPS_DIR="$BASE_DIR/repos"
CONFIG_DIR="$BASE_DIR/config"
UTILS_DIR="$BASE_DIR/src/utils"
INFRA_CHART_DIR="$BASE_DIR/src/deployer/helm/infra" 
NGINX_VALUES_FILE="$CONFIG_DIR/nginx_values.yaml"

# Mojaloop vNext 
# for gazelle 1.1.0 we have removed the ttk layer as it is not needed as we have MifosX instance integrated as DFSPs 
VNEXT_LAYER_DIRS=("$APPS_DIR/vnext/packages/installer/manifests/crosscut" "$APPS_DIR/vnext/packages/installer/manifests/apps" "$APPS_DIR/vnext/packages/installer/manifests/reporting")
VNEXT_VALUES_FILE="$CONFIG_DIR/vnext_values.json"

#PaymentHub EE 
PH_VALUES_FILE="$CONFIG_DIR/ph_values.yaml"

# Database setup script
# SQL_FILE="$BASE_DIR/src/deployer/setup.sql"

#MifosX 
MIFOSX_MANIFESTS_DIR="$APPS_DIR/mifosx/kubernetes/manifests"

########################################################################
# FUNCTIONS FOR CONFIGURATION MANAGEMENT
########################################################################
function replaceValuesInFiles() {
    local directories=("$@")
    local json_file="$VNEXT_VALUES_FILE"

    # Check if jq is installed, if not, exit with an error message
    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is not installed. Please install it (https://stedolan.github.io/jq/) and make sure it's in your PATH."
        return 1
    fi

    # Check if the JSON file exists
    if [ ! -f "$json_file" ]; then
        echo "Error: JSON file '$json_file' does not exist."
        return 1
    fi

    # Read the JSON file and create an associative array
    declare -A replacements
    while IFS= read -r json_object; do
        local old_value new_value
        old_value=$(echo "$json_object" | jq -r '.old_value')
        new_value=$(echo "$json_object" | jq -r '.new_value')
        replacements["$old_value"]="$new_value"
    done < <(jq -c '.[]' "$json_file")

    # Loop through the directories and process each file
    for dir in "${directories[@]}"; do
        if [ -d "$dir" ]; then
            find "$dir" -type f | while read -r file; do
                local changed=false
                for old_value in "${!replacements[@]}"; do
                    if grep -q "$old_value" "$file"; then
                        echo "Replacing '$old_value' with '${replacements[$old_value]}' in file '$file'"
                        #sed -i "s|$old_value|${replacements[$old_value]}|g" "$file"
                        #sed -i "s|.*$old_value.*|${replacements[$old_value]}|g" "$file"
                        sed -i "s|^\(.*\)$old_value.*|\1${replacements[$old_value]}|g" "$file"
                        changed=true
                    fi
                done
                if $changed; then
                    echo "Updated: $file" >> /dev/null 2>&1
                fi
            done
        else
            echo "Directory $dir does not exist."
        fi
    done
}

#------------------------------------------------------------------------------
# Function : configurevNext
# Description: Configures vNext manifests by replacing placeholder values 
#              and adjusting settings.
# Parameters: None
#------------------------------------------------------------------------------
function configurevNext() {
    echo -e "${BLUE}Configuring vNext manifests ${RESET}"
  replaceValuesInFiles "${VNEXT_LAYER_DIRS[0]}" "${VNEXT_LAYER_DIRS[1]}" "${VNEXT_LAYER_DIRS[2]}"
  echo "      Adjusting ingressClassName and domain names in vNext manifests"
  # Iterate over each directory in VNEXT_LAYER_DIRS
  for dir in "${VNEXT_LAYER_DIRS[@]}"; do
    # Find all YAML files in the directory
    find "$dir" -type f -name "*.yaml" | while read -r file; do
      # Perform the in-place substitution for ingressClassName
      perl -pi -e 's/ingressClassName:\s*nginx-ext/ingressClassName: nginx/' "$file"
      
      # Perform the in-place substitution for domain name .local to mifos.gazelle.test
      perl -pi -e 's/- host:\s*(\S+)\.local/- host: $1.mifos.gazelle.test/' "$file"
      perl -pi -e 's/(\S+)bank\.local/$1bank.mifos.gazelle.test/' "$file"

    done
 done
}

# function configureMifosx(){
#   echo -e "${BLUE}Configuring MifosX ${RESET}"
# }