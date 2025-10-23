#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

# source "$RUN_DIR/src/utils/logger.sh"
# source "$RUN_DIR/src/utils/helpers.sh" 
source "$RUN_DIR/src/deployer/core.sh" || { echo "FATAL: Could not source core.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/vnext.sh" || { echo "FATAL: Could not source vnext.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mifosx.sh" || { echo "FATAL: Could not source mifosx.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/phee.sh"   || { echo "FATAL: Could not source phee.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }  

function cloneRepo() {
  if [ "$#" -ne 4 ]; then
      echo "Usage: cloneRepo <branch> <repo_link> <target_directory> <cloned_directory_name>"
      return 1
  fi
  local branch="$1"
  local repo_link="$2"
  local target_directory="$3"
  local cloned_directory_name="$4"
  local repo_path="$target_directory/$cloned_directory_name"

  # Check if the target directory exists; if not, create it.
  if [ ! -d "$target_directory" ]; then
      mkdir -p "$target_directory"
  fi
  chown -R "$k8s_user" "$target_directory"

  # Check if the repository already exists.
  if [ -d "$repo_path" ]; then
    #echo "Repository $repo_path already exists. Checking for updates..."

    cd "$repo_path" || exit

    # Fetch the latest changes.
    su - "$k8s_user" -c "git fetch origin $branch" >> /dev/null 2>&1

    # Compare local branch with the remote branch.
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})

    if [ "$LOCAL" != "$REMOTE" ]; then
        echo -e "${YELLOW}Repository $repo_path has updates. Recloning...${RESET}"
        rm -rf "$repo_path"
        su - "$k8s_user" -c "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
    else
        echo "    Repository $repo_path is up-to-date. No need to reclone."
    fi
  else
    # Clone the repository if it doesn't exist locally.
    su - "$k8s_user" -c "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "    Repository $repo_path cloned successfully."
    else
        echo "** Error Failed to clone the repository."
    fi
  fi
}

function deleteResourcesInNamespaceMatchingPattern() {
    local pattern="$1"
    local exit_code=0 # Initialize exit code

    # Check if the pattern is provided
    if [ -z "$pattern" ]; then
        echo "Error: Pattern not provided."
        return 1
    fi
      
    #echo "DEBUG: Fetching namespaces matching pattern '$pattern'..."
    
    # Get all namespaces and filter them locally.
    local all_namespaces_output
    all_namespaces_output=$(run_as_user "kubectl get namespaces -o name" 2>&1)
    
    # Filter the output for namespaces matching the pattern, stripping the "namespace/" prefix.
    local matching_namespaces
    # The grep command will set $? to 1 if no matches are found, but we want the script to continue.
    matching_namespaces=$(echo "$all_namespaces_output" | grep -E "$pattern" | sed 's/^namespace\///' || true)

    if [ -z "$matching_namespaces" ]; then
        echo "No namespaces found matching pattern: $pattern"
        return 0
    fi
    
    # Read the namespaces line by line
    echo "$matching_namespaces" | while read -r namespace; do
        if [ -z "$namespace" ]; then
            continue # Skip empty lines
        fi
        
        # Explicitly skip 'default' to prevent accidental deletion of a core namespace
        if [[ "$namespace" == "default" ]]; then
            continue
        fi

        printf "Attempting to delete all resources and the namespace '$namespace'..."
        
        # Delete the namespace (this removes all resources within it)
        if run_as_user "kubectl delete ns \"$namespace\""; then
            echo " [ok]"
        else
            # run_as_user already logged the error, but we can log a summary here.
            echo " [FAILED]"
            echo "Failed to delete namespace $namespace. Check logs for details."
            exit_code=1 # Set exit code to indicate failure in the loop
        fi
        
    done
    
    # Return the aggregated exit code
    return $exit_code
}

# function deleteResourcesInNamespaceMatchingPattern() {
#     local pattern="$1"  
#     # Check if the pattern is provided
#     if [ -z "$pattern" ]; then
#         echo "Pattern not provided."
#         return 1
#     fi
    
#     # Get namespaces matching the pattern
#     echo "DEBUG Fetching namespaces"
#     full_pod_name=$(run_as_user "kubectl get pods -n \"$namespace\" --no-headers -o custom-columns=\":metadata.name\" | grep -i \"$pod_name\" | head -1")
#     su - "$k8s_user" -c "kubectl get namespaces" #2>/tmp/kubectl_error.log
#     if [ -s /tmp/kubectl_error.log ]; then
#         echo "Error fetching namespaces: $(cat /tmp/kubectl_error.log)"
#         return 1
#     fi

#     local namespaces
#     namespaces=$(su - "$k8s_user" -c "kubectl get namespaces -o name" 2>/tmp/kubectl_error.log | grep "$pattern" || true)
#     if [ -s /tmp/kubectl_error.log ]; then
#         echo "Error fetching namespaces with pattern '$pattern': $(cat /tmp/kubectl_error.log)"
#     fi
#     echo "DEBUG Namespaces matching pattern '$pattern': $namespaces"
#     if [ -z "$namespaces" ]; then
#         echo "No namespaces found matching pattern: $pattern"
#         return 0
#     fi
    
#     echo "$namespaces" | while read -r namespace; do
#         namespace=$(echo "$namespace" | cut -d'/' -f2)
#         echo "DEBUG Processing namespace: $namespace"
#         if [[ $namespace == "default" ]]; then
#             # there should not be resources deployed in the defaul namespace so we intentially skip it
#             continue  
#         else
#             printf "Deleting all resources in namespace $namespace "
#             su - "$k8s_user" -c "kubectl delete all --all -n \"$namespace\"" >/tmp/kubectl_delete.log 2>&1
#             su - "$k8s_user" -c "kubectl delete ns \"$namespace\"" >>/tmp/kubectl_delete.log 2>&1
#             if [ $? -eq 0 ]; then
#                 echo " [ok] "
#             else
#                 echo "Error deleting resources in namespace $namespace."
#                 echo "Error details: $(cat /tmp/kubectl_delete.log)"
#             fi
#         fi
#     done
# }

function deployHelmChartFromDir() {
  # Check if the chart directory exists
  local chart_dir="$1"
  local namespace="$2"
  local release_name="$3"
  if [ ! -d "$chart_dir" ]; then
    echo "Chart directory '$chart_dir' does not exist."
    exit 1
  fi
  # Check if a values file has been provided
  values_file="$4"

  if [ -n "$values_file" ]; then
      echo "Installing Helm chart using values: $values_file..."
      su - $k8s_user -c "helm install --wait --timeout 600s $release_name $chart_dir -n $namespace -f $values_file"
  else
      echo "Installing Helm chart using default values file ..."
      su - $k8s_user -c "helm install --wait --timeout 600s $release_name $chart_dir -n $namespace "
  fi

  # Use kubectl to get the resource count in the specified namespace
  resource_count=$(sudo -u $k8s_user kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)
  # Check if the deployment was successful
  if [ $resource_count -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
  fi

}

function createNamespace () {
  local namespace=$1
  printf "    Creating namespace $namespace "
  # Check if the namespace already exists
  if kubectl get namespace "$namespace" >> /dev/null 2>&1; then
      echo -e "${BLUE}Namespace $namespace already exists -skipping creation.${RESET}"
      return 0
  fi

  # Create the namespace
  kubectl create namespace "$namespace" >> /dev/null 2>&1
  if [ $? -eq 0 ]; then
      echo -e " [ok] "
  else
      echo "Failed to create namespace $namespace."
  fi
}

function deployInfrastructure () {
  local redeploy="$1"

  printf "==> Deploying infrastructure \n"
  result=$(isDeployed "infra" "$INFRA_NAMESPACE" "mysql-0")
  if [[ "$result" == "true" ]]; then
      if [[ "$redeploy" == "false" ]]; then
          echo "    infrastructure is already deployed. Skipping deployment."
          return
      else
          deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
      fi
  fi

  createNamespace $INFRA_NAMESPACE

  # Update helm dependencies and repo index for infra chart 
  printf  "    updating dependencies for infra helm chart "
  su - $k8s_user -c "cd $INFRA_CHART_DIR;  helm dep update" #>> DEBUG /dev/null 2>&1 
  check_command_execution "Updating dependencies for infra chart"
  echo " [ok] "

  #su - $k8s_user -c "cd $INFRA_CHART_DIR;  helm repo index ."
  printf "    Deploying infra helm chart  "
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
  else 
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
  fi
  check_command_execution "Deploying infra helm chart"
  echo  " [ok] "
  echo -e "\n${GREEN}============================"
  echo -e "Infrastructure Deployed"
  echo -e "============================${RESET}\n"
}

function applyKubeManifests() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: applyKubeManifests <directory> <namespace>"
        return 1
    fi
    local directory="$1"
    local namespace="$2"

    # Check if the directory exists.
    if [ ! -d "$directory" ]; then
        echo "Directory '$directory' not found."
        return 1
    fi

    # Apply persistence-related manifests first
    for file in "$directory"/*persistence*.yaml; do
      if [ -f "$file" ]; then
        su - $k8s_user -c "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        if [ $? -ne 0 ]; then
          echo -e "${RED}Failed to apply persistence manifest $file.${RESET}"
        fi
      fi
    done

    # Apply other manifests
    for file in "$directory"/*.yaml; do
      if [[ "$file" != *persistence*.yaml ]]; then
        su - $k8s_user -c "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        if [ $? -ne 0 ]; then
          echo -e "${RED}Failed to apply Kubernetes manifest $file.${RESET}"
        fi
      fi
    done
    # su - $k8s_user -c "kubectl apply -f $directory -n $namespace"  >> /dev/null 2>&1 
    # if [ $? -eq 0 ]; then
    #     echo -e "    Kubernetes manifests applied successfully."
    # else
    #     echo -e "${RED}Failed to apply Kubernetes manifests.${RESET}"
    # fi
}


function addKubeConfig(){
  K8sConfigDir="$k8s_user_home/.kube"

  if [ ! -d "$K8sConfigDir" ]; then
      su - $k8s_user -c "mkdir -p $K8sConfigDir"
      echo "K8sConfigDir created: $K8sConfigDir"
  else
      echo "K8sConfigDir already exists: $K8sConfigDir"
  fi
  su - $k8s_user -c "cp $k8s_user_home/k3s.yaml $K8sConfigDir/config"
}



function test_vnext {
  echo "TODO" #TODO Write function to test apps
}

function test_phee {
  echo "TODO"
}

function test_mifosx {
  local instance_name=$1
}

function printEndMessage {
  echo -e "================================="
  echo -e "Thank you for using Mifos Gazelle"
  echo -e "=================================\n\n"
  echo -e "CHECK DEPLOYMENTS USING kubectl"
  echo -e "kubectl get pods -n vnext #For testing mojaloop vNext"
  echo -e "kubectl get pods -n paymenthub #For testing PaymentHub EE "
  echo -e "kubectl get pods -n mifosx # for testing MifosX"
  echo -e "or install k9s by executing ./src/utils/install-k9s.sh <cr> in this terminal window\n\n"
}

# INFO: Updated function
function deleteApps {
  # appsToDelete will be a space-separated string (e.g., "vnext mifosx", "all", "infra")
  appsToDelete="$2"

  if [[ "$appsToDelete" == "all" ]]; then
    echo "Deleting all applications and related resources."
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "default"
  else
    # Iterate over each application in the space-separated list
    echo "Deleting specific applications: $appsToDelete"
    for app in $appsToDelete; do
      case "$app" in
        "vnext")
          deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
          ;;
        "mifosx")
          deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
          ;;
        "phee")
          deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
          ;;
        "infra")
          deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
          ;;
        *)
          echo -e "${RED}Invalid app '$app' for deletion. This should have been caught by validateInputs.${RESET}"
          showUsage
          exit 
          ;;
      esac
    done
  fi
}

# INFO: Updated function
function deployApps {
  # appsToDeploy will be a space-separated string, e.g., "vnext mifosx", "infra", "all"
  appsToDeploy="$2"
  redeploy="$3"
  echo "redeploy is $redeploy"

  echo -e "${BLUE}Starting deployment for applications: $appsToDeploy...${RESET}"

  # Special handling for 'all' as a block-deploy, matching the repo
  if [[ "$appsToDeploy" == "all" ]]; then
    echo -e "${BLUE}Deploying all apps ...${RESET}"
    deployInfrastructure "$redeploy"
    deployvNext
    deployPH
    DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR"
    deployBPMS
    generateMifosXandVNextData
  else
    # Process each application in the space-separated list
    for app in $appsToDeploy; do
      echo -e "${BLUE}--- Deploying '$app' ---${RESET}"
      case "$app" in
        "infra")
          deployInfrastructure
          ;;
        "vnext")
          deployInfrastructure "false"
          deployvNext
          ;;
        "mifosx")
          if [[ "$redeploy" == "true" ]]; then 
            echo "removing current mifosx and redeploying"
            deleteApps 1 "mifosx"
          fi 
          deployInfrastructure "false"
          DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR" 
          generateMifosXandVNextData
          ;;
        "phee")
          deployInfrastructure "false"
          deployPH
          ;;
        *)
          echo -e "${RED}Error: Unknown application '$app' in deployment list. This should have been caught by validation.${RESET}"
          showUsage
          exit 1
          ;;
      esac
      echo -e "${BLUE}--- Finished deploying '$app' ---${RESET}\n"
    done
  fi

  addKubeConfig >> /dev/null 2>&1
  printEndMessage
}
