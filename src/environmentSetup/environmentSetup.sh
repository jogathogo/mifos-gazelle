#!/usr/bin/env bash
# environmentSetup.sh -- Mifos Gazelle environment setup script

source "$RUN_DIR/src/utils/logger.sh" || { echo "FATAL: Could not source logger.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/k8s.sh" || { echo "FATAL: Could not source k8s.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

echo "DEBUG0"

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

function k8s_already_installed {
    if [[ -f "/usr/local/bin/k3s" ]]; then
        printf "==> k3s is already installed **\n"
        return 0
    fi
    return 1
}

function install_prerequisites {
    printf "\n\r==> Install any OS prerequisites, tools & updates  ...\n"
    if [[ $LINUX_OS == "Ubuntu" ]]; then
        if ! command -v docker &> /dev/null; then
            logWithVerboseCheck "$debug" debug "Docker is not installed. Installing Docker..."
            apt update >> /dev/null 2>&1
            apt install -y apt-transport-https ca-certificates curl software-properties-common >> /dev/null 2>&1
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> /dev/null 2>&1
            echo "deb [signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >> /dev/null 2>&1
            apt update >> /dev/null 2>&1
            apt install -y docker-ce docker-ce-cli containerd.io >> /dev/null 2>&1
            usermod -aG docker "$k8s_user"
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
            apt-get update >> /dev/null 2>&1
            apt-get -y install jq >> /dev/null 2>&1
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
        echo "k8s_user is $k8s_user"
        #export KUBECONFIG="/home/ubuntu/.kube/config"
        su - "$k8s_user" -c "echo $KUBECONFIG; kubectl get nodes"
        #su - "$k8s_user" -c "kubectl --kubeconfig=$KUBECONFIG get nodes"

        if [[ $? -eq 0 ]]; then
            printf "Successfully connected to the remote Kubernetes cluster.\n"
            report_cluster_info
        else
            printf "** Error: Failed to connect to the remote Kubernetes cluster. Ensure the kubeconfig file at %s is valid and the cluster is accessible.\n" "$kubeconfig_path"
            exit 1
        fi
    elif [[ "$cluster_type" == "local" ]]; then
        do_k3s_install
    else
        printf "Invalid choice. Defaulting to local\n"
        cluster_type="local"
        do_k3s_install
    fi
}

function delete_k8s {
    printf "==> removing any existing k3s installation and helm binary"
    rm -f /usr/local/bin/helm >> /dev/null 2>&1
    /usr/local/bin/k3s-uninstall.sh >> /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        printf " [ ok ] \n"
    else
        echo -e "\n==> k3s not installed"
    fi
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bashrc"
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bash_profile"
}

# function checkClusterConnection {
#     export KUBECONFIG="$kubeconfig_path"
#     printf "\r==> Check the cluster is available and ready from kubectl  "
#     k8s_ready=`su - "$k8s_user" -c "kubectl get nodes" | perl -ne 'print if s/^.*Ready.*$/Ready/'`
#     if [[ ! "$k8s_ready" == "Ready" ]]; then
#         printf "** Error: kubernetes is not reachable  ** \n"
#         exit 1
#     fi
#     printf "    [ ok ] \n"
# }

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

function configure_k8s_user_env {
    start_message="# GAZELLE_START start of config added by mifos-gazelle #"
    grep "start of config added by mifos-gazelle" "$k8s_user_home/.bashrc" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        printf "==> Adding kubernetes configuration for %s .bashrc\n" "$k8s_user"
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
        printf "\r==> Kubernetes configuration for .bashrc for user %s already exists ..skipping\n" "$k8s_user"
    fi
}


function envSetupMain {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run using sudo "
        exit 1
    fi

    if [ $# -lt 11 ]; then
        showUsage
        echo "Not enough arguments -m mode, -v k8s_version, -e environment, -u k8s_user, kubeconfig_path, helm_version, k8s_current_release_list, min_ram, min_free_space, linux_os_list, and ubuntu_ok_versions_list must be specified"
        exit 1
    fi
echo "DEBUG1"
echo "DEBUG RUN_DIR is $RUN_DIR"
    mode="$1"
    k8s_user_version="$2"
    environment="$3"
    k8s_user="$4"
    kubeconfig_path="$5"
    HELM_VERSION="$6"
    K8S_CURRENT_RELEASE_LIST="$7"
    MIN_RAM="${8}"
    MIN_FREE_SPACE="${9}"
    LINUX_OS_LIST="${10}"
    UBUNTU_OK_VERSIONS_LIST="${11}"

    # Convert space-separated lists to arrays
    IFS=' ' read -r -a K8S_CURRENT_RELEASE_LIST <<< "$K8S_CURRENT_RELEASE_LIST"
    IFS=' ' read -r -a LINUX_OS_LIST <<< "$LINUX_OS_LIST"
    IFS=' ' read -r -a UBUNTU_OK_VERSIONS_LIST <<< "$UBUNTU_OK_VERSIONS_LIST"

    K8S_VERSION=""
    CURRENT_RELEASE="false"
    k8s_user_home=""
    k8s_arch=`uname -p`

    if [[ -z "$kubeconfig_path" ]]; then
        k8s_user_home=`eval echo "~$k8s_user"`
        kubeconfig_path="$k8s_user_home/.kube/config"
        logWithVerboseCheck "$debug" info "No kubeconfig_path provided, defaulting to $kubeconfig_path"
    fi

    logWithVerboseCheck "$debug" info "Starting envSetupMain with mode=$mode, k8s_version=$k8s_user_version, environment=$environment, k8s_user=$k8s_user, kubeconfig_path=$kubeconfig_path, helm_version=$HELM_VERSION, k8s_current_release_list=${K8S_CURRENT_RELEASE_LIST[*]}, min_ram=$MIN_RAM, min_free_space=$MIN_FREE_SPACE, linux_os_list=${LINUX_OS_LIST[*]}, ubuntu_ok_versions_list=${UBUNTU_OK_VERSIONS_LIST[*]}"

    check_arch_ok
    verify_user
    set_user

    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        if [[ "$environment" == "local" ]]; then
            set_k8s_version
            if ! k8s_already_installed; then 
                check_os_ok
                install_prerequisites
                add_hosts
                setup_k8s_cluster "$environment"
                install_nginx "$environment"
                install_k8s_tools
                add_helm_repos
                configure_k8s_user_env
                $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
            # else 
            #     checkHelmandKubectl
            fi
        else
            echo "Remote cluster selected"
            check_os_ok
            install_prerequisites
            install_k8s_tools
            setup_k8s_cluster "$environment"
            #install_nginx "$environment"

            add_helm_repos
            configure_k8s_user_env
            #$UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        fi
        # checkClusterConnection
        printf "\r==> kubernetes k3s version:[%s] is now configured for user [%s] and ready for Mifos Gazelle deployment\n" \
               "$K8S_VERSION" "$k8s_user"
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