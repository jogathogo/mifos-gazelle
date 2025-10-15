#!/usr/bin/env bash

# Source required scripts
#source "$RUN_DIR/src/configurationManager/config.sh"

function check_arch_ok {
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "arm64" && "$arch" != "aarch64" ]]; then
        printf " **** Error: mifos-gazelle only works properly with x86_64, arm64, or aarch64 architectures today  *****\n"
        exit 1 
    fi
}

function check_resources_ok {
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    free_space=$(df -BG ~ | awk '{print $4}' | tail -n 1 | sed 's/G//')
    if [[ "$total_ram" -lt "$MIN_RAM" ]]; then
        printf " ** Error: mifos-gazelle currently requires $MIN_RAM GBs to run properly \n"
        printf "    Please increase RAM available before trying to run mifos-gazelle \n"
        exit 1
    fi
    if [[ "$free_space" -lt "$MIN_FREE_SPACE" ]] ; then
        printf " ** Warning: mifos-gazelle currently requires %sGBs free storage in %s home directory  \n" "$MIN_FREE_SPACE" "$k8s_user"
        printf "    but only found %sGBs free storage \n" "$free_space"
        printf "    mifos-gazelle installation will continue, but beware it might fail later due to insufficient storage \n"
    fi
}

function checkHelmandKubectl {
    if ! command -v helm &>/dev/null; then
        echo "Helm is not installed. Please install Helm first."
        exit 1
    fi
    if ! command -v kubectl &>/dev/null; then
        echo "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
} 

function set_user {
    logWithVerboseCheck "$debug" info "k8s user is $k8s_user"
}

function k8s_already_installed {
    if [[ -f "/usr/local/bin/k3s" ]]; then
        printf "==> k3s is already installed **\n"
        return 0
    fi
    if [[ -f "/snap/bin/microk8s" ]]; then
        printf "** warning, microk8s is already installed, using existing deployment  **\n"
        return 0 
    fi
    return 1
}

function set_linux_os_distro {
    LINUX_VERSION="Unknown"
    if [ -x "/usr/bin/lsb_release" ]; then
        LINUX_OS=`lsb_release --d | perl -ne 'print if s/^.*Ubuntu.*(\d+).(\d+).*$/Ubuntu/' `
        LINUX_VERSION=`/usr/bin/lsb_release --d | perl -ne 'print $& if m/(\d+)/' `
    else
        LINUX_OS="Untested"
    fi
    printf "\r==> Linux OS is [%s] " "$LINUX_OS"
}

function check_os_ok {
    printf "\r==> checking OS and kubernetes distro is tested with mifos-gazelle scripts\n"
    set_linux_os_distro
    if [[ ! $LINUX_OS == "Ubuntu" ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu OS at this time   **\n"
        exit 1
    fi
    if [[ ! " ${UBUNTU_OK_VERSIONS_LIST[*]} " =~ " ${LINUX_VERSION} " ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu versions 22.xx or 24.xx at this time   **\n"
        exit 1
    fi
}

function install_prerequisites {
    printf "\n\r==> Install any OS prerequisites, tools & updates  ...\n"
    if [[ $LINUX_OS == "Ubuntu" ]]; then
        #printf "\rapt update \n"
        #apt update > /dev/null 2>&1
        if [[ $k8s_distro == "microk8s" ]]; then
            printf "   install snapd\n"
            apt install snapd -y > /dev/null 2>&1
        fi
        if ! command -v docker &> /dev/null; then
            logWithVerboseCheck "$debug" debug "Docker is not installed. Installing Docker..."
            sudo apt update >> /dev/null 2>&1
            sudo apt install -y apt-transport-https ca-certificates curl software-properties-common >> /dev/null 2>&1
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> /dev/null 2>&1
            echo "deb [signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >> /dev/null 2>&1
            sudo apt update >> /dev/null 2>&1
            sudo apt install -y docker-ce docker-ce-cli containerd.io >> /dev/null 2>&1
            sudo usermod -aG docker "$k8s_user"
            printf "ok \n"
        else
            logWithVerboseCheck "$debug" debug "Docker is already installed.\n"
        fi
        if ! command -v nc &> /dev/null; then
            logWithVerboseCheck "$debug" debug "nc (netcat) is not installed. Installing..."
            apt-get update >> /dev/null 2>&1
            apt-get install -y netcat >> /dev/null 2>&1
            printf "ok\n"
        else
            logWithVerboseCheck "$debug" debug "nc (netcat) is already installed.\n"
        fi
        if ! command -v jq &> /dev/null; then
            logWithVerboseCheck "$debug" debug "jq is not installed. Installing ..."
            sudo apt-get update >> /dev/null 2>&1
            sudo apt-get -y install jq >> /dev/null 2>&1
            printf "ok\n"
        else
            logWithVerboseCheck "$debug" debug "jq is already installed\n"
        fi
    fi
}

function add_hosts {
    if [[ "$environment" == "local" ]]; then
        printf "==> Mifos-gazelle: update hosts file for local environment\n"
        VNEXTHOSTS=( mongohost.mifos.gazelle.test mongo-express.mifos.gazelle.test \
                     vnextadmin.mifos.gazelle.test kafkaconsole.mifos.gazelle.test elasticsearch.mifos.gazelle.test redpanda-console.mifos.gazelle.test \
                     fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test \
                     bluebank-specapi.mifos.gazelle.test greenbank-specapi.mifos.gazelle.test )
        PHEEHOSTS=( ops.mifos.gazelle.test ops-bk.mifos.gazelle.test \
                    bulk-connector.mifos.gazelle.test messagegateway.mifos.gazelle.test \
                    minio-console.mifos.gazelle.test bill-pay.mifos.gazelle.test channel.mifos.gazelle.test \
                    channel-gsma.mifos.gazelle.test crm.mifos.gazelle.test mockpayment.mifos.gazelle.test \
                    mojaloop.mifos.gazelle.test identity-mapper.mifos.gazelle.test vouchers.mifos.gazelle.test \
                    zeebeops.mifos.gazelle.test zeebe-operate.mifos.gazelle.test zeebe-gateway.mifos.gazelle.test \
                    elastic-phee.mifos.gazelle.test kibana-phee.mifos.gazelle.test notifications.mifos.gazelle.test )
        MIFOSXHOSTS=( mifos.mifos.gazelle.test fineract.mifos.gazelle.test )
        ALLHOSTS=( "127.0.0.1" "localhost" "${MIFOSXHOSTS[@]}" "${PHEEHOSTS[@]}" "${VNEXTHOSTS[@]}" )
        export ENDPOINTS=`echo ${ALLHOSTS[*]}`
        perl -pi -e 's/^(127\.0\.0\.1\s+)(.*)/$1localhost/' /etc/hosts
        perl -p -i.bak -e 's/127\.0\.0\.1.*localhost.*$/$ENV{ENDPOINTS} /' /etc/hosts
    else
        printf "==> Skipping /etc/hosts modification for remote environment. Ensure DNS is configured for Mifos Gazelle services.\n"
    fi
}

function set_k8s_distro {
    if [ -z ${k8s_distro+x} ]; then
        k8s_distro=$DEFAULT_K8S_DISTRO
        printf "==> Using default kubernetes distro [%s]\n" "$k8s_distro"
    else
        k8s_distro=`echo "$k8s_distro" | perl -ne 'print lc'`
        if [[ "$k8s_distro" == "microk8s" || "$k8s_distro" == "k3s" ]]; then
            printf "\r==> kubernetes distro set to [%s] \n" "$k8s_distro"
        else
            printf "** Error: invalid kubernetes distro specified. Valid options are microk8s or k3s \n"
            exit 1
        fi
    fi
}

function print_current_k8s_releases {
    printf "          Current Kubernetes releases are: "
    for i in "${K8S_CURRENT_RELEASE_LIST[@]}"; do
        printf " [v%s]" "$i"
    done
    printf "\n"
}

function set_k8s_version {
    if [ ! -z ${k8s_user_version+x} ] ; then
        k8s_user_version=`echo $k8s_user_version | tr -d A-Z | tr -d a-z `
        for i in "${K8S_CURRENT_RELEASE_LIST[@]}"; do
            if [[ "$k8s_user_version" == "$i" ]]; then
                CURRENT_RELEASE=true
                break
            fi
        done
        if [[ $CURRENT_RELEASE == true ]]; then
            K8S_VERSION=$k8s_user_version
        else
            printf "** Error: The specified kubernetes release [ %s ] is not a current release \n" "$k8s_user_version"
            printf "          when using the -v flag you must specify a current supported release \n"
            print_current_k8s_releases
            printf "** \n"
            exit 1
        fi
    else
        printf "** Error: kubernetes release has not been specified with the -v flag  \n"
        printf "          you must supply the -v flag and specify a current supported release \n\n"
        showUsage
        exit 1
    fi
    printf "\r==> kubernetes version to install set to [%s] \n" "$K8S_VERSION"
}

function verify_user {
    if [ -z ${k8s_user+x} ]; then
        printf "** Error: The operating system user has not been specified with the -u flag \n"
        printf "          the user specified with the -u flag must exist and not be the root user \n"
        printf "** \n"
        exit 1
    fi
    if [[ `id -u $k8s_user >/dev/null 2>&1; echo $?` == 0 ]]; then
        if [[ `id -u $k8s_user` == 0 ]]; then
            printf "** Error: The user specified by -u should be a non-root user ** \n"
            exit 1
        fi
    else
        printf "** Error: The user [ %s ] does not exist in the operating system \n" "$k8s_user"
        printf "            please try again and specify an existing user \n"
        printf "** \n"
        exit 1
    fi
    k8s_user_home=`eval echo "~$k8s_user"`
}

function do_microk8s_install {
    printf "==> Installing Kubernetes MicroK8s & enabling tools (helm, ingress, etc) \n"
    echo "==> Microk8s Install: installing microk8s release $k8s_user_version ... "
    rm -rf "$k8s_user_home/.kube" >> /dev/null 2>&1
    snap install microk8s --classic --channel=$K8S_VERSION/stable
    microk8s.status --wait-ready
    microk8s.enable helm3
    microk8s.enable dns
    echo "==> enable storage ... "
    microk8s.enable storage
    microk8s.enable ingress
    echo "==> add convenient aliases..."
    snap alias microk8s.kubectl kubectl
    snap alias microk8s.helm3 helm
    echo "==> add $k8s_user user to microk8s group"
    usermod -a -G microk8s "$k8s_user"
    mkdir -p "$(dirname "$kubeconfig_path")"
    microk8s config > "$kubeconfig_path"
    chown "$k8s_user" "$kubeconfig_path"
    chmod 600 "$kubeconfig_path"
    export KUBECONFIG="$kubeconfig_path"
    logWithVerboseCheck "$debug" debug "Microk8s kubeconfig written to $kubeconfig_path"
}

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
    cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
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
    local k8s_distro=$2
    printf "\r==> Installing NGINX ingress controller and waiting for it to be ready\n"
    if check_nginx_running; then 
        printf "[ NGINX ingress controller already installed and running ]\n"
        if [[ "$cluster_type" == "remote" ]]; then
            get_ingress_ip
        fi
        return 0 
    fi 
    if [[ "$cluster_type" == "local" ]]; then 
        if [[ "$k8s_distro" == "microk8s" ]]; then 
            microk8s.enable ingress
            printf "[ok]\n"
        else
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

function install_kubectl {
    printf "\r==> kubectl is not installed. Installing latest stable version...\n"
    local arch=$(uname -m)
    local kubectl_arch="amd64"
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
        kubectl_arch="arm64"
    fi
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${kubectl_arch}/kubectl"
    chmod +x ./kubectl
    mv ./kubectl /usr/local/bin/kubectl
    if ! command -v kubectl &>/dev/null; then
        printf "** Error: Failed to install kubectl **\n"
        exit 1
    fi
    printf "\r==> kubectl installed successfully.\n"
}

function report_cluster_info {
    export KUBECONFIG="$kubeconfig_path"
    num_nodes=$(kubectl get nodes --no-headers | wc -l)
    k8s_version=$(kubectl version | grep Server | awk '{print $3}')
    printf "\r==> Cluster is available.\n"
    printf "    Number of nodes: %s\n" "$num_nodes"
    printf "    Kubernetes version: %s\n" "$k8s_version"
}

function setup_k8s_cluster {
    local cluster_type=$1
    if [ -z "$cluster_type" ]; then
        printf "Cluster type not set. Defaulting to local\n"
        cluster_type="local"
    fi
    if [[ ! -f "$kubeconfig_path" && "$cluster_type" == "remote" ]]; then
        printf "** Error: kubeconfig file at %s does not exist for remote cluster **\n" "$kubeconfig_path"
        exit 1
    fi
    if [[ "$cluster_type" == "remote" ]]; then
        if ! command -v kubectl &>/dev/null; then
            install_kubectl
        fi
        export KUBECONFIG="$kubeconfig_path"
        logWithVerboseCheck "$debug" debug "Using kubeconfig: $KUBECONFIG for remote cluster"
        printf "Verifying connection to the remote Kubernetes cluster...\n"
        kubectl get nodes >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            printf "Successfully connected to the remote Kubernetes cluster.\n"
            report_cluster_info
        else
            printf "** Error: Failed to connect to the remote Kubernetes cluster. Ensure the kubeconfig file at %s is valid and the cluster is accessible.\n" "$kubeconfig_path"
            exit 1
        fi
    elif [[ "$cluster_type" == "local" ]]; then
        if [[ "$k8s_distro" == "microk8s" ]]; then
            do_microk8s_install
        else
            do_k3s_install
        fi
    else
        printf "Invalid choice. Defaulting to local\n"
        cluster_type="local"
        if [[ "$k8s_distro" == "microk8s" ]]; then
            do_microk8s_install
        else
            do_k3s_install
        fi
    fi
}

function delete_k8s {
    if [[ "$k8s_distro" == "microk8s" ]]; then
        printf "==> removing any existing Microk8s installation "
        snap remove microk8s > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            printf " [ ok ] \n"
        else
            printf " [ microk8s delete failed ] \n"
            printf "** was microk8s installed ?? \n"
            printf "   if so please try running \"sudo snap remove microk8s\" manually ** \n"
        fi
    else
        printf "==> removing any existing k3s installation and helm binary"
        rm -f /usr/local/bin/helm >> /dev/null 2>&1
        /usr/local/bin/k3s-uninstall.sh >> /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            printf " [ ok ] \n"
        else
            echo -e "\n==> k3s not installed"
        fi
    fi
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bashrc"
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bash_profile"
}

function checkClusterConnection {
    export KUBECONFIG="$kubeconfig_path"
    printf "\r==> Check the cluster is available and ready from kubectl  "
    k8s_ready=`su - "$k8s_user" -c "kubectl get nodes" | perl -ne 'print if s/^.*Ready.*$/Ready/'`
    if [[ ! "$k8s_ready" == "Ready" ]]; then
        printf "** Error: kubernetes is not reachable  ** \n"
        exit 1
    fi
    printf "    [ ok ] \n"
}

function print_end_message {
    echo -e "\n${GREEN}============================"
    echo -e "Environment setup successful"
    echo -e "============================${RESET}\n"
}

function print_end_message_tear_down {
    echo -e "\n\n=================================================="
    echo -e "Thank you for using Mifos-gazelle cleanup successful"
    echo -e "======================================================\n\n"
    echo -e "Copyright © 2023 The Mifos Initiative"
}

function install_k8s_tools {
    printf "\r==> Checking and installing Kubernetes tools\n"

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64|arm64) ARCH_TYPE="arm64" ;;
        *) echo "Unsupported architecture: $ARCH"; return 1 ;;
    esac

    # Array of tools and their installation details
    declare -A tools=(
        ["kubens"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubens_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kubectx"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubectx_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kustomize"]="https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
        ["k9s"]="https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH_TYPE}.tar.gz"
        ["helm"]="https://get.helm.sh/helm-v3.16.2-linux-${ARCH_TYPE}.tar.gz"
    )

    for tool in "${!tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "$tool is already installed, skipping installation"
        else
            if [[ "$tool" == "kustomize" ]]; then
                curl -s "${tools[$tool]}" | bash > /dev/null 2>&1
            else
                curl -s -L "${tools[$tool]}" | tar xz -C . > /dev/null 2>&1
                if [[ "$tool" == "helm" ]]; then
                    mv linux-${ARCH_TYPE}/helm ./"$tool" > /dev/null 2>&1
                    rm -rf linux-${ARCH_TYPE} > /dev/null 2>&1
                fi
            fi
            mv ./"$tool" /usr/local/bin > /dev/null 2>&1
            echo "$tool installed successfully"
        fi
    done
}

function add_helm_repos {
    printf "\r==> add the helm repos required to install and run infrastructure for vNext, Paymenthub EE and MifosX\n"
    export KUBECONFIG="$kubeconfig_path"
    su - "$k8s_user" -c "helm repo add kiwigrid https://kiwigrid.github.io" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add kokuwa https://kokuwaio.github.io/helm-charts" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add codecentric https://codecentric.github.io/helm-charts" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add bitnami https://charts.bitnami.com/bitnami" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add cowboysysop https://cowboysysop.github.io/charts/" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo add redpanda-data https://charts.redpanda.com/" > /dev/null 2>&1
    su - "$k8s_user" -c "helm repo update" > /dev/null 2>&1
}

function configure_k8s_user_env {
    start_message="# GAZELLE_START start of config added by mifos-gazelle #"
    grep "start of config added by mifos-gazelle" "$k8s_user_home/.bashrc" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        printf "==> Adding configuration for %s to %s .bashrc\n" "$k8s_distro" "$k8s_user"
        printf "%s\n" "$start_message" >> "$k8s_user_home/.bashrc"
        echo "source <(kubectl completion bash)" >> "$k8s_user_home/.bashrc"
        echo "alias k=kubectl " >> "$k8s_user_home/.bashrc"
        echo "complete -F __start_kubectl k " >> "$k8s_user_home/.bashrc"
        echo "alias ksetns=\"kubectl config set-context --current --namespace\" " >> "$k8s_user_home/.bashrc"
        echo "alias ksetuser=\"kubectl config set-context --current --user\" " >> "$k8s_user_home/.bashrc"
        echo "alias cdg=\"cd $k8s_user_home/mifos-gazelle\" " >> "$k8s_user_home/.bashrc"
        echo "export PATH=\$PATH:/usr/local/bin" >> "$k8s_user_home/.bashrc"
        echo "export KUBECONFIG=$kubeconfig_path" >> "$k8s_user_home/.bashrc"
        printf "#GAZELLE_END end of config added by mifos-gazelle #\n" >> "$k8s_user_home/.bashrc"
        perl -p -i.bak -e 's/^.*KUBECONFIG.*$//g' "$k8s_user_home/.bash_profile"
        echo "source .bashrc" >> "$k8s_user_home/.bash_profile"
        echo "export KUBECONFIG=$kubeconfig_path" >> "$k8s_user_home/.bash_profile"
    else
        printf "\r==> Configuration for .bashrc for %s for user %s already exists ..skipping\n" "$k8s_distro" "$k8s_user"
    fi
}

function envSetupMain {
    DEFAULT_K8S_DISTRO="k3s"
    K8S_VERSION=""
    HELM_VERSION="3.18.4"
    OS_VERSIONS_LIST=( 22 24 )
    K8S_CURRENT_RELEASE_LIST=( "1.31" "1.32" ) 
    CURRENT_RELEASE="false"
    k8s_user_home=""
    k8s_arch=`uname -p`
    MIN_RAM=6
    MIN_FREE_SPACE=30
    LINUX_OS_LIST=( "Ubuntu" )
    UBUNTU_OK_VERSIONS_LIST=( 22 24 )

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit 1
    fi

    if [ $# -lt 6 ]; then
        showUsage
        echo "Not enough arguments -m mode, -k k8s_distro, -v k8s_version, -e environment, -u k8s_user, and kubeconfig_path must be specified"
        exit 1
    fi

    mode="$1"
    k8s_distro="$2"
    k8s_user_version="$3"
    environment="$4"
    k8s_user="$5"
    kubeconfig_path="$6"

    if [[ -z "$kubeconfig_path" ]]; then
        k8s_user_home=`eval echo "~$k8s_user"`
        kubeconfig_path="$k8s_user_home/.kube/config"
        logWithVerboseCheck "$debug" info "No kubeconfig_path provided, defaulting to $kubeconfig_path"
    fi

    logWithVerboseCheck "$debug" info "Starting envSetupMain with mode=$mode, k8s_distro=$k8s_distro, k8s_version=$k8s_user_version, environment=$environment, k8s_user=$k8s_user, kubeconfig_path=$kubeconfig_path"

    check_arch_ok
    verify_user
    set_user

    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        set_k8s_distro
        if [[ "$environment" == "local" ]]; then
            set_k8s_version
            if ! k8s_already_installed; then 
                check_os_ok
                install_prerequisites
                add_hosts
                setup_k8s_cluster "$environment"
                install_nginx "$environment" "$k8s_distro"
                install_k8s_tools
                add_helm_repos
                configure_k8s_user_env
                $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
            else 
                checkHelmandKubectl
            fi
        else # remote cluster 
            check_os_ok
            install_prerequisites
            setup_k8s_cluster "$environment"
            #install_nginx "$environment" "$k8s_distro"
            install_k8s_tools
            add_helm_repos
            configure_k8s_user_env
            $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        fi
        checkClusterConnection
        printf "\r==> kubernetes distro:[%s] version:[%s] is now configured for user [%s] and ready for Mifos Gazelle deployment\n" \
               "$k8s_distro" "$K8S_VERSION" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanall" ]]; then
        if [[ "$environment" == "local" ]]; then
            echo "Deleting local kubernetes cluster..."
            delete_k8s
            echo "Local Kubernetes deleted" 
        fi
        print_end_message_tear_down
    else
        showUsage
        exit 1
    fi
}