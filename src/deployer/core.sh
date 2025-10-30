#!/usr/bin/env bash
# core.sh -- functios that are core to the deployer script(s)

#------------------------------------------------------
# Function : is_app_running
# Description: Check if the application is deployed by 
# verifying the number of "Ready" pods in a namespace
#------------------------------------------------------
function is_app_running() {
    local namespace="$1"
    local min_pods=2
    
    # Validate inputs
    [[ -z "$namespace" ]] && {
        logWithVerboseCheck "$debug" error "Namespace missing: namespace=$namespace"
        return 1
    }
    
    # Debug: Print namespace and minimum pods
    logWithVerboseCheck "$debug" debug "Checking for at least $min_pods pods, all Ready, in namespace $namespace"
    
    # Check if namespace exists
    local namespace_check
    namespace_check=$(run_as_user "kubectl get namespace \"$namespace\" -o name")
    local namespace_exit_code=$?
    logWithVerboseCheck "$debug" debug "Namespace check exit code: $namespace_exit_code, output: [$namespace_check]"
    [[ $namespace_exit_code -ne 0 ]] && {
        logWithVerboseCheck "$debug" error "Namespace $namespace does not exist or is inaccessible"
        return 1
    }
    
    local raw_output
    raw_output=$(run_as_user "kubectl get pod -n \"$namespace\" --no-headers -o wide")
    local exit_code=$?

    # Strip any lines that look like debug/command echo (e.g., "DEBUG Running as ...")
    pod_list=$(echo "$raw_output" | grep -v 'DEBUG' | grep -v "kubectl" || true)
    
    # Count total pods and ready pods
    total_pods=$(echo "$pod_list" | grep -c '^')
    # Modified to count pods where READY column shows all containers ready (e.g., 1/1, 2/2)
    ready_count=$(echo "$pod_list" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && $2 !~ /0\/[0-9]+/ {print $0}' | grep -c '^')
    
    # Debug: Print kubectl exit code, pod list, total pods, and ready count
    logWithVerboseCheck "$debug" debug "kubectl exit code: $exit_code, pod list: [$pod_list], total pods: $total_pods, ready pods: $ready_count"
    
    # Check if command failed
    [[ $exit_code -ne 0 ]] && {
        logWithVerboseCheck "$debug" error "Failed to retrieve pods in namespace $namespace"
        return 1
    }
    
    # Check if there are enough pods and all are Ready
    if [[ $total_pods -ge $min_pods && $total_pods -eq $ready_count ]]; then
        logWithVerboseCheck "$debug" debug "Found $total_pods pods, all Ready, in namespace $namespace, meeting minimum of $min_pods"
        return 0
    else
        logWithVerboseCheck "$debug" debug "Check failed: $total_pods pods, $ready_count Ready, in namespace $namespace (requires at least $min_pods pods, all Ready)"
        return 1
    fi
} # end of is_app_running

#------------------------------------------------------------------------------
# Function : createIngressSecret   
# Description: Creates a self-signed TLS certificate and stores it as a Kubernetes secret.
# Parameters: 
#   $1 - Namespace to create the secret in  
#   $2 - Domain name for the certificate
#   $3 - Secret name
#------------------------------------------------------------------------------
function createIngressSecret {
    local namespace="$1"
    local domain_name="$2"
    local secret_name="$3"
    local key_dir="$k8s_user_home/.ssh"

    # Ensure key_dir exists and is accessible
    mkdir -p "$key_dir" || { echo " ** Error creating directory $key_dir: $?"; exit 1; }
    ls -ld "$key_dir" > /dev/null 2>&1 || echo "DEBUG: Directory $key_dir listing failed"

    # Generate private key
    openssl genrsa -out "$key_dir/$domain_name.key" 2048 >/dev/null 2>&1 || { echo " ** Error generating private key: $?"; ls -l "$key_dir/$domain_name.key" 2>/dev/null || echo "DEBUG: Key file not found"; exit 1; }

    # Verify key file exists and is readable
    if [ ! -f "$key_dir/$domain_name.key" ]; then
        echo " ** Error: Private key $key_dir/$domain_name.key was not created"
        exit 1
    fi
    # DEBUG ls -l "$key_dir/$domain_name.key"

    # Generate self-signed certificate
    openssl req -x509 -new -nodes -key "$key_dir/$domain_name.key" -sha256 -days 365 -out "$key_dir/$domain_name.crt" -subj "/CN=$domain_name" -extensions v3_req -config <(
        cat <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $domain_name
[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = $domain_name
EOF
    ) >/dev/null 2>&1 || { echo " ** Error generating certificate: $?"; ls -l "$key_dir/$domain_name.crt" 2>/dev/null || echo "DEBUG: Certificate file not found"; exit 1; }

    # Verify certificate file exists and is readable
    if [ ! -f "$key_dir/$domain_name.crt" ]; then
        echo " ** Error: Certificate $key_dir/$domain_name.crt was not created"
        exit 1
    fi
    # DEBUG ls -l "$key_dir/$domain_name.crt"

    # Verify the certificate
    openssl x509 -in "$key_dir/$domain_name.crt" -noout -text >/dev/null 2>&1 || { echo " ** Error verifying certificate: $?"; exit 1; }

    # Change ownership of certificate files to k8s_user
    # Ensure permissions are restrictive but readable by k8s_user
    chown "$k8s_user":"$k8s_user" "$key_dir/$domain_name.crt" "$key_dir/$domain_name.key" || { echo " ** Error changing ownership of certificate files: $?"; ls -l "$key_dir/$domain_name."{crt,key}; exit 1; }
    chmod 600 "$key_dir/$domain_name.crt" "$key_dir/$domain_name.key" || { echo " ** Error setting permissions on certificate files: $?"; ls -l "$key_dir/$domain_name."{crt,key}; exit 1; }

    # Verify k8s_user can access the files
    #su - "$k8s_user" -c "test -r \"$key_dir/$domain_name.crt\" && test -r \"$key_dir/$domain_name.key\"" || { echo " ** Error: $k8s_user cannot read certificate files"; ls -l "$key_dir/$domain_name."{crt,key}; exit 1; }

    # Create the Kubernetes TLS secret using run_as_user
    local kubectl_output
    kubectl_output=$(run_as_user "kubectl create secret tls \"$secret_name\" --cert=\"$key_dir/$domain_name.crt\" --key=\"$key_dir/$domain_name.key\" -n \"$namespace\"" 2>&1)
    local kubectl_exit_code=$?

    if [ $kubectl_exit_code -ne 0 ]; then
        echo "   ** Error creating self-signed certificate and secret $secret_name in namespace $namespace"
        echo "   ** kubectl error output: $kubectl_output"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Function : manageElasticSecrets
# Description: Creates or deletes Elasticsearch related Kubernetes secrets.
# Parameters:
#   $1 - Action: "create" or "delete"
#   $2 - Namespace where the secrets are managed
#   $3 - Directory containing the .p12 certificate file
#------------------------------------------------------------------------------
function manageElasticSecrets {
    local action="$1"
    local namespace="$2"
    local certdir="$3" # location of the .p12 and .pem files 
    local password="XVYgwycNuEygEEEI0hQF"

    # Verify input parameters
    if [ -z "$action" ] || [ -z "$namespace" ] || [ -z "$certdir" ]; then
        echo " ** Error: Missing required parameters (action, namespace, certdir)"
        return 1
    fi

    # Verify certdir exists and is readable
    if [ ! -d "$certdir" ] || [ ! -r "$certdir/elastic-certificates.p12" ]; then
        echo " ** Error: certdir $certdir does not exist or elastic-certificates.p12 is not readable"
        return 1
    fi

    # Create a temporary directory owned by k8s_user
    local temp_dir
    temp_dir=$(mktemp -d -p "/tmp" "elastic_secrets_XXXXXX") || { echo " ** Error: Failed to create temporary directory"; return 1; }
    chown "$k8s_user":"$k8s_user" "$temp_dir" || { echo " ** Error: Failed to change ownership of $temp_dir"; rm -rf "$temp_dir"; return 1; }
    chmod 700 "$temp_dir" || { echo " ** Error: Failed to set permissions on $temp_dir"; rm -rf "$temp_dir"; return 1; }

    # Check if k8s_user can access certdir
    if ! su - "$k8s_user" -c "test -r '$certdir/elastic-certificates.p12'" 2>/dev/null; then
        # Copy certificates to temp_dir
        cp "$certdir/elastic-certificates.p12" "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to copy certificates"; rm -rf "$temp_dir"; return 1; }
        chown "$k8s_user":"$k8s_user" "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to change ownership of copied certificates"; rm -rf "$temp_dir"; return 1; }
        chmod 600 "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to set permissions on copied certificates"; rm -rf "$temp_dir"; return 1; }
        certdir="$temp_dir"
    fi

    if [ "$action" = "create" ]; then
        # Convert certificates
        if ! openssl pkcs12 -nodes -passin pass:'' -in "$certdir/elastic-certificates.p12" -out "$temp_dir/elastic-certificate.pem" >/dev/null 2>&1; then
            echo " ** Error: Failed to convert p12 to pem"
            rm -rf "$temp_dir"
            return 1
        fi
        if ! openssl x509 -outform der -in "$temp_dir/elastic-certificate.pem" -out "$temp_dir/elastic-certificate.crt" >/dev/null 2>&1; then
            echo " ** Error: Failed to convert pem to crt"
            rm -rf "$temp_dir"
            return 1
        fi

        # Ensure generated files are owned by k8s_user
        if ! chown "$k8s_user":"$k8s_user" "$temp_dir/elastic-certificate.pem" "$temp_dir/elastic-certificate.crt"; then
            echo " ** Error: Failed to change ownership of generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi
        if ! chmod 600 "$temp_dir/elastic-certificate.pem" "$temp_dir/elastic-certificate.crt"; then
            echo " ** Error: Failed to set permissions on generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi

        # Verify k8s_user can access generated files
        if ! su - "$k8s_user" -c "test -r '$temp_dir/elastic-certificate.pem' && test -r '$temp_dir/elastic-certificate.crt'" 2>/dev/null; then
            echo " ** Error: $k8s_user cannot read generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi

        # Create secrets
        local secret_output
        secret_output=$(run_as_user "kubectl create secret generic elastic-certificates --namespace=\"$namespace\" --from-file=\"$certdir/elastic-certificates.p12\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificates secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-certificate-pem --namespace=\"$namespace\" --from-file=\"$temp_dir/elastic-certificate.pem\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificate-pem secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-certificate-crt --namespace=\"$namespace\" --from-file=\"$temp_dir/elastic-certificate.crt\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificate-crt secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-credentials --namespace=\"$namespace\" --from-literal=password=\"$password\" --from-literal=username=elastic" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-credentials secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        local encryptionkey="MMFI5EFpJnib4MDDbRPuJ1UNIRiHuMud_r_EfBNprx7qVRlO7R"
        secret_output=$(run_as_user "kubectl create secret generic kibana --namespace=\"$namespace\" --from-literal=encryptionkey=$encryptionkey" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating kibana secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        rm -rf "$temp_dir"  # Clean up on success

    elif [ "$action" = "delete" ]; then
        local secrets=("elastic-certificates" "elastic-certificate-pem" "elastic-certificate-crt" "elastic-credentials" "kibana")
        local all_success=true

        for secret in "${secrets[@]}"; do
            local delete_output
            delete_output=$(run_as_user "kubectl delete secret $secret --namespace=\"$namespace\" --ignore-not-found=true" 2>&1)
            if [ $? -ne 0 ] && [[ ! "$delete_output" =~ "not found" ]]; then
                echo " ** Warning: Failed to delete secret $secret: $delete_output"
                all_success=false
            fi
            # echo "DEBUG removed secret $secret in namespace $namespace ok" 
        done

        if [ "$all_success" = false ]; then
            rm -rf "$temp_dir"
            return 1
        fi
        rm -rf "$temp_dir"

    else
        echo " ** Error: Invalid action. Use 'create' or 'delete'."
        rm -rf "$temp_dir"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Function to update FQDN in YAML files (Helm values or Kubernetes manifests)
# Example usage:
#   update_fqdn "values.yaml" "hostname.mifos.gazelle.test" "hostname.newdomain.com"
#------------------------------------------------------------------------------
update_fqdn() {
    local input_file="$1"
    local old_fqdn="$2"
    local new_fqdn="$3"
    
    # Validate parameters
    if [ $# -ne 3 ]; then
        echo "Error: Invalid number of arguments"
        echo "Usage: update_fqdn <input_file> <old_fqdn> <new_fqdn>"
        return 1
    fi
    
    # Check if file exists
    if [ ! -f "$input_file" ]; then
        echo "Error: File '$input_file' does not exist"
        return 1
    fi
    
    # Check if file is writable
    if [ ! -w "$input_file" ]; then
        echo "Error: File '$input_file' is not writable"
        return 1
    fi
    
    # Create backup with timestamp
    local backup_file="${input_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$input_file" "$backup_file"
    # echo "Created backup: $backup_file"
    
    # Escape dots in FQDNs for sed (dots are special characters in regex)
    local escaped_old_fqdn=$(echo "$old_fqdn" | sed 's/\./\\./g')
    local escaped_new_fqdn=$(echo "$new_fqdn" | sed 's/\./\\./g')
    
    # Perform the replacement in-place
    sed -i.tmp "s/${escaped_old_fqdn}/${new_fqdn}/g" "$input_file"
    rm -f "${input_file}.tmp"
    
    # Count number of replacements made
    local changes=$(diff -u "$backup_file" "$input_file" | grep "^[-+]" | grep -v "^[-+][-+][-+]" | wc -l)
    
    if [ "$changes" -gt 0 ]; then
        # echo "Successfully updated $input_file"
        # echo "Changes made: $((changes / 2)) line(s) modified"
        # echo ""
        # echo "Preview of changes:"
        # diff -u "$backup_file" "$input_file" | head -20
        rm -f "$backup_file"
        return 0
    else
        echo "No changes made to $input_file (FQDN not found)"
        rm "$backup_file"  # Remove backup if no changes
        return 0
    fi
    rm -f "$backup_file"
}

#------------------------------------------------------------------------------
# Function to update all YAML files in a directory structure
# Example:
#   update_fqdn_batch "mydir" "mifos.gazelle.test" "newdomain.com"
#------------------------------------------------------------------------------
update_fqdn_batch() {
    local directory="$1"
    local old_fqdn="$2"
    local new_fqdn="$3"
    
    find "$directory" -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r file; do
        #echo "Processing: $file"
        update_fqdn "$file" "$old_fqdn" "$new_fqdn"
        #echo "---"
    done
}



# Update all Gazelle FQDN references
# update_gazelle_domain() {
#     local new_domain="$1"
#     local old_domain="mifos.gazelle.test"
    
#     # Update Helm values
#     find . -name "values*.yaml" -exec bash -c 'update_fqdn "$0" "'"$old_domain"'" "'"$new_domain"'"' {} \;
    
#     # Update Kubernetes manifests
#     find . -name "*.yaml" -path "*/kubernetes/*" -exec bash -c 'update_fqdn "$0" "'"$old_domain"'" "'"$new_domain"'"' {} \;
# }
