#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script


# Check if a pod is running in the specified namespace
# isPodRunning() {
#     local podname="$1" namespace="$2"
#     if [[ -z "$podname" || -z "$namespace" ]]; then
#         logWithVerboseCheck "$debug" error "Pod name or namespace missing: podname=$podname, namespace=$namespace"
#         return 1
#     fi
#     local pod_status
#     pod_status=$(run_as_user "kubectl get pod \"$podname\" -n \"$namespace\" -o jsonpath='{.status.phase}' 2>/dev/null")
#     local exit_code=$?
#     if [[ $exit_code -ne 0 ]]; then
#         logWithVerboseCheck "$debug" debug "Pod $podname in namespace $namespace not found or error occurred"
#         return 1
#     fi
#     if [[ "$pod_status" == "Running" ]]; then
#         logWithVerboseCheck "$debug" debug "Pod $podname in namespace $namespace is Running"
#         return 0
#     else
#         logWithVerboseCheck "$debug" debug "Pod $podname in namespace $namespace is not Running (status: $pod_status)"
#         return 1
#     fi
# }

# isDeployed() {
#     local app_name="$1" namespace="$2" pod_name="$3" full_pod_name

#     # Check if namespace exists
#     run_as_user "kubectl get namespace \"$namespace\" "  || return 1

#     # Get the full pod name
#     full_pod_name=$(run_as_user "kubectl get pods -n \"$namespace\" --no-headers -o custom-columns=\":metadata.name\" | grep -i \"$pod_name\" | head -1")

#     # If no pod found, return false
#     [[ -z "$full_pod_name" ]] && return 1

#     # Check if the pod is running
#     if isPodRunning "$full_pod_name" "$namespace"; then
#         return 0
#     else
#         return 1
#     fi
# }

#------------------------------------------------------
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
    
    # Get all pods
    local pod_list total_pods ready_count
    pod_list=$(run_as_user "kubectl get pod -n \"$namespace\" --no-headers -o wide")
    local exit_code=$?
    
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



# isDeployed_old() {
#     local app_name="$1" namespace="$2" pod_name="$3" full_pod_name
#     kubectl get namespace "$namespace" >/dev/null 2>&1 || { echo "false"; return; }
#     full_pod_name=$(run_as_user "kubectl get pods -n \"$namespace\" --no-headers -o custom-columns=\":metadata.name\" | grep -i \"$pod_name\" | head -1")
#     if [[ -z "$full_pod_name" ]]; then
#         echo "false"
#         return
#     fi
#     if isPodRunning "$full_pod_name" "$namespace"; then
#         echo "true"
#     else
#         echo "false"
#     fi
# }

waitForPodReadyByPartialName() {
  local namespace="$1"
  local partial_podname="$2"
  local max_wait_seconds=300
  local sleep_interval=5
  local elapsed=0
  local podname

  while (( elapsed < max_wait_seconds )); do
    podname=$(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name" | grep -i "$partial_podname" | head -1)

    if [[ -n "$podname" ]]; then
      # Check if pod is Ready (Ready condition == True)
      local ready_status
      ready_status=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

      if [[ "$ready_status" == "True" ]]; then
        echo "$podname"
        return 0
      fi
    fi

    echo "⏳ Waiting for pod matching '$partial_podname' to be Ready in namespace '$namespace'... ($elapsed seconds elapsed)"
    sleep "$sleep_interval"
    ((elapsed+=sleep_interval))
  done

  echo -e "${RED}    Error: Pod matching '$partial_podname' did not become Ready within 5 minutes.${RESET}" >&2
  return 1
}

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



#create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
# function manageElasticSecrets {
#     local action="$1"
#     local namespace="$2"
#     local certdir="$3" # location of the .p12 and .pem files 
#     local password="XVYgwycNuEygEEEI0hQF"  

#     # Create a temporary directory to store the generated files
#     temp_dir=$(mktemp -d)

#     if [[ "$action" == "create" ]]; then
#       echo "    creating elastic and kibana secrets in namespace $namespace" 
#       # Convert the certificates and store them in the temporary directory
#       openssl pkcs12 -nodes -passin pass:'' -in $certdir/elastic-certificates.p12 -out "$temp_dir/elastic-certificate.pem"  >> /dev/null 2>&1
#       openssl x509 -outform der -in "$certdir/elastic-certificate.pem" -out "$temp_dir/elastic-certificate.crt"  >> /dev/null 2>&1

#       # Create the ES secrets in the specified namespace
#       kubectl create secret generic elastic-certificates --namespace="$namespace" --from-file="$certdir/elastic-certificates.p12" >> /dev/null 2>&1
#       kubectl create secret generic elastic-certificate-pem --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.pem" >> /dev/null 2>&1
#       kubectl create secret generic elastic-certificate-crt --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.crt" >> /dev/null 2>&1
#       kubectl create secret generic elastic-credentials --namespace="$namespace" --from-literal=password="$password" --from-literal=username=elastic >> /dev/null 2>&1

#       local encryptionkey=MMFI5EFpJnib4MDDbRPuJ1UNIRiHuMud_r_EfBNprx7qVRlO7R 
#       kubectl create secret generic kibana --namespace="$namespace" --from-literal=encryptionkey=$encryptionkey >> /dev/null 2>&1

#     elif [[ "$action" == "delete" ]]; then
#       echo "Deleting elastic and kibana secrets" 
#       # Delete the secrets from the specified namespace
#       kubectl delete secret elastic-certificates --namespace="$namespace" >> /dev/null 2>&1
#       kubectl delete secret elastic-certificate-pem --namespace="$namespace" >> /dev/null 2>&1
#       kubectl delete secret elastic-certificate-crt --namespace="$namespace" >> /dev/null 2>&1
#       kubectl delete secret elastic-credentials --namespace="$namespace" >> /dev/null 2>&1
#       kubectl delete secret  kibana --namespace="$namespace" >> /dev/null 2>&1
#     else
#       echo "Invalid action. Use 'create' or 'delete'."
#       rm -rf "$temp_dir"  # Clean up the temporary directory
#       return 1
#     fi

#     # Clean up the temporary directory
#     rm -rf "$temp_dir"
# }