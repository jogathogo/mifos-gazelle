#!/usr/bin/env bash
# environmentSetup.sh -- Mifos Gazelle environment setup script

source "$RUN_DIR/src/utils/logger.sh" || { echo "FATAL: Could not source logger.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/k8s.sh" || { echo "FATAL: Could not source k8s.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

echo "DEBUG0"


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




# function report_cluster_info {
#     export KUBECONFIG="$kubeconfig_path"
#     num_nodes=$(kubectl get nodes --no-headers | wc -l)
#     k8s_version=$(kubectl version | grep Server | awk '{print $3}')
#     printf "\r==> Cluster is available.\n"
#     printf "    Number of nodes: %s\n" "$num_nodes"
#     printf "    Kubernetes version: %s\n" "$k8s_version"
# }

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
        # if ! command -v kubectl &>/dev/null; then
        #     install_kubectl
        # fi
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



function envSetupRemoteCluster {
    check_sudo  # might not be needed for remote but leave for consistency 
    verify_user
    # # are helm and  kubectl installed
    # if ! checkTools kubectl; then
    #     echo "kubectl is not installed."
    # fi
    if [[ "$mode" == "deploy" ]]; then
        echo "remote- check kubectl" 
        echo "remote - check connection to cluster"
    else 
        if ! is_local_cluster_installed; then
            printf "==> Local kubernetes cluster is NOT installed\n"
            exit 1
        fi
    fi
} 

#     # Verify cluster access
#     echo "DEBUG 6a[envVerify] kubeconfig_path is $kubeconfig_path"
#     export KUBECONFIG="$kubeconfig_path"
#     #logWithVerboseCheck "$debug" debug "Verifying cluster access with KUBECONFIG=$KUBECONFIG"
#     local k8s_ready=$(su - "$k8s_user" -c "kubectl get nodes" | perl -ne 'print if s/^.*Ready.*$/Ready/' || echo "NotReady")
#     if [[ "$k8s_ready" != "Ready" ]]; then
#         logWithVerboseCheck "$debug" error "Kubernetes is not reachable or not ready"
#         exit 1
#     fi
#     echo "DEBUG 7a envsetup" 

#     # Ensure user environment is configured
#     configure_k8s_user_env
#     logWithVerboseCheck "$debug" info "Environment verification completed"
# }


# function envSetupLocalCluster {
#     local mode="$1"

#     check_sudo
#     check_arch_ok
#     verify_user
#     check_os_ok
#     if [[ "$mode" == "deploy" ]]; then
#         check_resources_ok
#         install_prerequisites
#     else 
#         if ! is_local_k8s_already_installed; then
#             printf "==> Local kubernetes cluster is NOT installed\n"
#             exit 1
#         fi
#     fi
# } 

function envSetupLocalCluster {
    local mode="$1"
    check_sudo
    check_arch_ok
    verify_user
    check_os_ok  
    install_k8s_tools

    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        install_prerequisites
        if ! is_local_k8s_already_installed; then
            add_hosts
            setup_k8s_cluster "$environment"
            install_nginx "$environment"
            add_helm_repos
            $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        # else
        #     checkHelmandKubectl
        fi
        printf "\r==> kubernetes k3s version:[%s] is now configured for user [%s] and ready for Mifos Gazelle deployment\n" \
               "$k8s_version" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanapps" ]]; then
        if ! is_local_k8s_already_installed; then
            printf "==> Local kubernetes cluster is NOT installed\n"
            exit 1
        fi
    elif [[ "$mode" == "cleanall" ]]; then
        echo "Deleting local kubernetes cluster..."
        if ! is_local_k8s_already_installed; then
            printf "==> Local kubernetes cluster is NOT installed\n"
            exit 1
        fi
        delete_k8s
        echo "Local Kubernetes deleted"
        print_end_message_tear_down
    else
        showUsage
        exit 1
    fi
}   

function envSetupMain {
    local mode="$1"

echo "DEBUG10 envsetuptools" 
    install_k8s_tools
    # K8S_VERSION=""
    # CURRENT_RELEASE="false"
    # k8s_arch=$(uname -p)


    # # is kubectl installed
    # if ! checkTools kubectl; then
    #     echo "kubectl is not installed."
    # fi

    echo "DEBUG9 [envsetupMain] k8s_version is $k8s_version"
    #install_prerequisites
    if [[ "$environment" == "local" ]]; then
        envSetupLocalCluster "$mode"
    elif [[ "$environment" == "remote" ]]; then
        envSetupRemoteCluster "$mode"
    else
        printf "** Error: Invalid environment type specified: %s. Must be 'local' or 'remote'. **\n" "$environment"
        exit 1
    fi
} 

