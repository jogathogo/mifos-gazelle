#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

# Function to check and handle command execution errors
check_command_execution() {
  local msg=$1
  if [ $? -ne 0 ]; then
    echo "Error: $1 failed"
    exit 1
  fi
}

# Debug function to check if a function exists
function function_exists() {
    declare -f "$1" > /dev/null
    return $?
}

function isPodRunning() {
    local podname="$1" namespace="$2"
    if [[ -z "$podname" || -z "$namespace" ]]; then
        return 1
    fi
    local pod_status
    pod_status=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$pod_status" == "Running" ]]
}

isDeployed() {
    local app_name="$1" namespace="$2" pod_name="$3" full_pod_name
    kubectl get namespace "$namespace" >/dev/null 2>&1 || { echo "false"; return; }
    full_pod_name=$(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name" | grep -i "$pod_name" | head -1)
    if [[ -z "$full_pod_name" ]]; then
        echo "false"
        return
    fi
    if isPodRunning "$full_pod_name" "$namespace"; then
        echo "true"
    else
        echo "false"
    fi
}

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
    key_dir="$HOME/.ssh"

    # Generate private key
    openssl genrsa -out "$key_dir/$domain_name.key" 2048 >> /dev/null 2>&1 

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
) > /dev/null 2>&1 
    # Verify the certificate
    openssl x509 -in "$key_dir/$domain_name.crt" -noout -text > /dev/null 2>&1 

    # Create the Kubernetes TLS secret
    kubectl create secret tls "$secret_name" --cert="$key_dir/$domain_name.crt" --key="$key_dir/$domain_name.key" -n "$namespace" > /dev/null 2>&1 

    if [ $? -eq 0 ]; then
      echo "    Self-signed certificate and secret $secret_name created successfully in namespace $namespace "
    else
      echo " ** Error creating Self-signed certificate and secret $secret_name in namespace $namespace "
      exit 1 
    fi 
} 

function manageElasticSecrets {
    local action="$1"
    local namespace="$2"
    local certdir="$3" # location of the .p12 and .pem files 
    local password="XVYgwycNuEygEEEI0hQF"  #see 

    # Create a temporary directory to store the generated files
    temp_dir=$(mktemp -d)

    if [[ "$action" == "create" ]]; then
      echo "    creating elastic and kibana secrets in namespace $namespace" 
      # Convert the certificates and store them in the temporary directory
      openssl pkcs12 -nodes -passin pass:'' -in $certdir/elastic-certificates.p12 -out "$temp_dir/elastic-certificate.pem"  >> /dev/null 2>&1
      openssl x509 -outform der -in "$certdir/elastic-certificate.pem" -out "$temp_dir/elastic-certificate.crt"  >> /dev/null 2>&1

      # Create the ES secrets in the specified namespace
      kubectl create secret generic elastic-certificates --namespace="$namespace" --from-file="$certdir/elastic-certificates.p12" >> /dev/null 2>&1
      kubectl create secret generic elastic-certificate-pem --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.pem" >> /dev/null 2>&1
      kubectl create secret generic elastic-certificate-crt --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.crt" >> /dev/null 2>&1
      kubectl create secret generic elastic-credentials --namespace="$namespace" --from-literal=password="$password" --from-literal=username=elastic >> /dev/null 2>&1

      local encryptionkey=MMFI5EFpJnib4MDDbRPuJ1UNIRiHuMud_r_EfBNprx7qVRlO7R 
      kubectl create secret generic kibana --namespace="$namespace" --from-literal=encryptionkey=$encryptionkey >> /dev/null 2>&1

    elif [[ "$action" == "delete" ]]; then
      echo "Deleting elastic and kibana secrets" 
      # Delete the secrets from the specified namespace
      kubectl delete secret elastic-certificates --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-certificate-pem --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-certificate-crt --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-credentials --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret  kibana --namespace="$namespace" >> /dev/null 2>&1
    else
      echo "Invalid action. Use 'create' or 'delete'."
      rm -rf "$temp_dir"  # Clean up the temporary directory
      return 1
    fi

    # Clean up the temporary directory
    rm -rf "$temp_dir"
}