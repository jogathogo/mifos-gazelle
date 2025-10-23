#!/usr/bin/env bash
# kubernetes specific functions 

function do_k3s_install {
    printf "========================================================================================\n"
    printf "Mifos-gazelle k3s install: Installing Kubernetes k3s engine and tools (helm/ingress etc) \n"
    printf "========================================================================================\n"
    rm -rf "$k8s_user_home/.kube" >> /dev/null 2>&1
    printf "\r==> installing k3s "
    curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
                            INSTALL_K3S_CHANNEL="v$K8S_VERSION" \
                            INSTALL_K3S_EXEC=" --disable traefik " sh > /dev/null 2>&1
    status=`k3s check-config 2> /dev/null | grep "^STATUS" | awk '{print $2}' `
    if [[ "$status" != "pass" ]]; then
        printf "** Error: k3s check-config not reporting status of pass   ** \n"
        printf "   run k3s check-config manually as user [%s] for more information   ** \n" "$k8s_user"
        exit 1
    fi
    printf "[ok]\n"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    sudo chown "$k8s_user" "$KUBECONFIG"
    mkdir -p "$(dirname "$kubeconfig_path")"
    #DEBUG/TODO this needs fixing for local and remote 
    # cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
    chown "$k8s_user" "$kubeconfig_path"
    chmod 600 "$kubeconfig_path"
    export KUBECONFIG="$kubeconfig_path"
    logWithVerboseCheck "$debug" debug "k3s kubeconfig copied to $kubeconfig_path"
    # printf "\r==> installing helm "
    # helm_arch_str=""
    # if [[ "$k8s_arch" == "x86_64" ]]; then
    #     helm_arch_str="amd64"
    # elif [[ "$k8s_arch" == "aarch64" ]]; then
    #     helm_arch_str="arm64"
    # else
    #     printf "** Error: architecture not recognised as x86_64 or arm64  ** \n"
    #     exit 1
    # fi
    # rm -rf /tmp/linux-"$helm_arch_str" /tmp/helm.tar
    # curl -L -s -o /tmp/helm.tar.gz https://get.helm.sh/helm-v$HELM_VERSION-linux-"$helm_arch_str".tar.gz
    # gzip -d /tmp/helm.tar.gz
    # tar xf /tmp/helm.tar -C /tmp
    # mv /tmp/linux-"$helm_arch_str"/helm /usr/local/bin
    # rm -rf /tmp/linux-"$helm_arch_str"
    # /usr/local/bin/helm version > /dev/null 2>&1
    # if [[ $? -ne 0 ]]; then
    #     printf "** Error: helm install seems to have failed ** \n"
    #     exit 1
    # fi
    printf "[ok]\n"
}

function check_nginx_running {
    export KUBECONFIG="$kubeconfig_path"
    nginx_pod_name=$(kubectl get pods -n ingress-nginx --no-headers -o custom-columns=":metadata.name" | grep nginx | head -n 1)
    if [ -z "$nginx_pod_name" ]; then
        return 1
    fi
    pod_status=$(kubectl get pod -n ingress-nginx "$nginx_pod_name" -o jsonpath='{.status.phase}')
    if [ "$pod_status" == "Running" ]; then
        return 0
    else
        return 1
    fi
}

function get_ingress_ip {
    export KUBECONFIG="$kubeconfig_path"
    ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -z "$ingress_ip" ]; then
        ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -z "$ingress_ip" ]; then
            ingress_ip="not-assigned"
        fi
    fi
    printf "\r==> NGINX Ingress Controller external address: %s\n" "$ingress_ip"
    if [[ "$ingress_ip" == "not-assigned" ]]; then
        printf "    Note: No external IP or hostname assigned yet. It may take a few minutes for the cloud provider to assign one.\n"
        printf "    Run 'kubectl get svc -n ingress-nginx ingress-nginx-controller' to check the status.\n"
    else
        printf "    Configure DNS to point Mifos Gazelle domains (e.g., *.mifos.gazelle.test) to %s\n" "$ingress_ip"
    fi
}

function install_nginx {
    local cluster_type=$1
    printf "\r==> Installing NGINX ingress controller and waiting for it to be ready\n"
    if check_nginx_running; then 
        printf "[ NGINX ingress controller already installed and running ]\n"
        if [[ "$cluster_type" == "remote" ]]; then
            get_ingress_ip
        fi
        return 0 
    fi 
    if [[ "$cluster_type" == "local" ]]; then 
        export KUBECONFIG="$kubeconfig_path"
        su - "$k8s_user" -c "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx" > /dev/null 2>&1
        su - "$k8s_user" -c "helm repo update" > /dev/null 2>&1
        su - "$k8s_user" -c "helm delete ingress-nginx -n ingress-nginx" > /dev/null 2>&1
        su - "$k8s_user" -c "helm install ingress-nginx ingress-nginx/ingress-nginx \
                            --create-namespace --namespace ingress-nginx \
                            --set controller.service.type=NodePort \
                            --wait --timeout 1200s \
                            -f $NGINX_VALUES_FILE" > /dev/null 2>&1
        if check_nginx_running; then 
            printf "[ok]\n"
        else
            printf "** Error: Helm install of NGINX ingress controller failed, pod is not running **\n"
            exit 1
        fi
    else
        export KUBECONFIG="$kubeconfig_path"
        su - "$k8s_user" -c "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx" > /dev/null 2>&1
        su - "$k8s_user" -c "helm repo update" > /dev/null 2>&1
        su - "$k8s_user" -c "helm delete ingress-nginx -n ingress-nginx" > /dev/null 2>&1
        su - "$k8s_user" -c "helm install ingress-nginx ingress-nginx/ingress-nginx \
                          --create-namespace --namespace ingress-nginx \
                          --set controller.service.type=LoadBalancer \
                          --wait --timeout 1200s" > /dev/null 2>&1
        if check_nginx_running; then 
            printf "[ok]\n"
            get_ingress_ip
        else
            printf "** Error: Helm install of NGINX ingress controller failed, pod is not running **\n"
            exit 1
        fi
    fi
}

function install_k8s_tools {
    printf "\r==> Checking and installing Kubernetes tools\n"

    # --- NOTE ON VERSIONING ---
    # Define these versions globally (or ensure they are passed in)
    local kubectl_version="v1.30.0"
    local helm_version="v3.14.4"

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64|arm64) ARCH_TYPE="arm64" ;;
        *) echo "Unsupported architecture: $ARCH"; return 1 ;;
    esac
    echo "Detected architecture: $ARCH_TYPE (Using version kubectl $kubectl_version and helm $helm_version)"

    # Array of tools and their installation details
    declare -A tools=(
        # kubectl uses the official download site, which provides the executable directly.
        ["kubectl"]="https://dl.k8s.io/release/${kubectl_version}/bin/linux/${ARCH_TYPE}/kubectl"
        ["kubens"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubens_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kubectx"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubectx_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kustomize"]="https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
        ["k9s"]="https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH_TYPE}.tar.gz"
        ["helm"]="https://get.helm.sh/helm-${helm_version}-linux-${ARCH_TYPE}.tar.gz"
    )

    for tool in "${!tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            if [[ "$debug" == "true" ]]; then
                echo "DEBUG: $tool is already installed at $(command -v $tool)"
            fi
            echo "$tool is already installed. Skipping."
            continue
        else
            echo "Installing $tool..."
            # Installation logic
            if [[ "$tool" == "kustomize" ]]; then
                # kustomize uses a special install script
                curl -s "${tools[$tool]}" | bash > /dev/null 2>&1

            elif [[ "$tool" == "kubectl" ]]; then
                # kubectl is a direct executable download, so we save it and make it executable
                curl -s -L "${tools[$tool]}" -o ./"$tool"
                chmod +x ./"$tool"

            else
                # Install archives (kubens, kubectx, k9s, helm)
                curl -s -L "${tools[$tool]}" | tar xz -C . > /dev/null 2>&1
                if [[ "$tool" == "helm" ]]; then
                    # Helm has a nested structure after extraction
                    mv linux-${ARCH_TYPE}/helm ./"$tool" > /dev/null 2>&1
                    rm -rf linux-${ARCH_TYPE} > /dev/null 2>&1
                fi
            fi

            # Move the resulting executable(s) to the bin path
            if [[ "$tool" != "kustomize" ]]; then
                mv ./"$tool" /usr/local/bin > /dev/null 2>&1
            fi
            
            # Verify installation
            if command -v "$tool" >/dev/null 2>&1; then
                echo "$tool installed successfully."
            else
                echo "Error: $tool installation failed."
            fi
        fi
    done
}

function add_helm_repos {
    printf "\r==> add the helm repos required to install and run infrastructure for vNext, Paymenthub EE and MifosX\n"
    #export KUBECONFIG="$kubeconfig_path"
    su - "$k8s_user" -c "helm repo add kiwigrid https://kiwigrid.github.io" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add kokuwa https://kokuwaio.github.io/helm-charts" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add codecentric https://codecentric.github.io/helm-charts" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add bitnami https://charts.bitnami.com/bitnami" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add cowboysysop https://cowboysysop.github.io/charts/" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add redpanda-data https://charts.redpanda.com/" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo update" > /dev/null 2>&1
}

function report_cluster_info {
    export KUBECONFIG="$kubeconfig_path"
    num_nodes=$(kubectl get nodes --no-headers | wc -l)
    k8s_version=$(kubectl version | grep Server | awk '{print $3}')
    printf "\r==> Cluster is available.\n"
    printf "    Number of nodes: %s\n" "$num_nodes"
    printf "    Kubernetes version: %s\n" "$k8s_version"
}
