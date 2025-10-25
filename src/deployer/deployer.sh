#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

source "$RUN_DIR/src/deployer/core.sh" || { echo "FATAL: Could not source core.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/vnext.sh" || { echo "FATAL: Could not source vnext.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mifosx.sh" || { echo "FATAL: Could not source mifosx.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/phee.sh"   || { echo "FATAL: Could not source phee.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }  
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

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

  # Ensure target directory exists with correct ownership
  if [ ! -d "$target_directory" ]; then
      mkdir -p "$target_directory"
      chown -R "$k8s_user" "$target_directory"
  fi

  # Check if the repository already exists
  if [ -d "$repo_path" ]; then
    cd "$repo_path" || exit

    # Fetch the latest changes
    run_as_user "git fetch origin $branch" >> /dev/null 2>&1
    check_command_execution $? "git fetch origin $branch"

    # Compare local branch with remote branch
    local LOCAL REMOTE
    LOCAL=$(run_as_user "cd $repo_path && git rev-parse @")
    check_command_execution $? "git rev-parse @"
    
    REMOTE=$(run_as_user "cd $repo_path && git rev-parse @{u}")
    check_command_execution $? "git rev-parse @{u}"

    if [ "$LOCAL" != "$REMOTE" ]; then
        echo -e "${YELLOW}Repository $repo_path has updates. Recloning...${RESET}"
        rm -rf "$repo_path"
        run_as_user "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
        check_command_execution $? "git clone -b $branch $repo_link $repo_path"
    else
        echo "    Repository $repo_path is up-to-date. No need to reclone."
    fi
  else
    # Clone the repository if it doesn't exist locally
    run_as_user "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
    check_command_execution $? "git clone -b $branch $repo_link $repo_path"
    echo "    Repository $repo_path cloned successfully."
  fi
}

function deleteResourcesInNamespaceMatchingPattern() {
    local pattern="$1"
    
    if [ -z "$pattern" ]; then
        echo "Error: Pattern not provided."
        return 1
    fi
        
    # Get all namespaces and filter them locally
    local all_namespaces_output matching_namespaces
    all_namespaces_output=$(run_as_user "kubectl get namespaces -o name" 2>&1)
    check_command_execution $? "kubectl get namespaces -o name"
    
    # Filter the output for namespaces matching the pattern, stripping the "namespace/" prefix
    # grep returns 1 if no matches, but we want to continue, hence || true
    matching_namespaces=$(echo "$all_namespaces_output" | grep -E "$pattern" | sed 's/^namespace\///' || true)

    if [ -z "$matching_namespaces" ]; then
        echo "No namespaces found matching pattern: $pattern"
        return 0
    fi
    
    local exit_code=0
    # Read the namespaces line by line
    while read -r namespace; do
        # Skip empty lines and 'default' namespace
        if [ -z "$namespace" ] || [[ "$namespace" == "default" ]]; then
            continue
        fi

        printf "Attempting to delete all resources and the namespace '$namespace'..."
        
        # Delete the namespace (this removes all resources within it)
        if run_as_user "kubectl delete ns \"$namespace\""; then
            echo " [ok]"
        else
            echo " [FAILED]"
            echo "Failed to delete namespace $namespace. Check logs for details."
            exit_code=1
        fi
    done <<< "$matching_namespaces"
    
    return $exit_code
}

function deployHelmChartFromDir() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: deployHelmChartFromDir <chart_dir> <namespace> <release_name> [values_file]"
    return 1
  fi

  local chart_dir="$1"
  local namespace="$2"
  local release_name="$3"
  local values_file="$4"

  if [ ! -d "$chart_dir" ]; then
    echo "Error: Chart directory '$chart_dir' does not exist."
    return 1
  fi

  # Build helm install command
  local helm_cmd="helm install --wait --timeout 600s $release_name $chart_dir -n $namespace"
  
  if [ -n "$values_file" ]; then
      echo "Installing Helm chart using values: $values_file..."
      helm_cmd="$helm_cmd -f $values_file"
  else
      echo "Installing Helm chart using default values file..."
  fi

  run_as_user "$helm_cmd"
  check_command_execution $? "$helm_cmd"

  # Verify deployment
  local resource_count
  resource_count=$(run_as_user "kubectl get pods -n \"$namespace\" --ignore-not-found=true 2>/dev/null | grep -v 'No resources found' | wc -l")
  
  if [ "$resource_count" -gt 0 ]; then
    echo "Helm chart deployed successfully."
    return 0
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    return 1
  fi
}

function createNamespace() {
  local namespace=$1
  
  printf "    Creating namespace $namespace "
  # Check if the namespace already exists
  if run_as_user "kubectl get namespace \"$namespace\"" ; then
      echo -e "${BLUE}Namespace $namespace already exists - skipping creation.${RESET}"
  else
    # Create the namespace
    run_as_user "kubectl create namespace \"$namespace\"" >> /dev/null 2>&1
    check_command_execution
  fi
  printf " [ok] "
}

function deployInfrastructure() {
  local redeploy="${1:-false}"

  printf "==> Deploying infrastructure \n"
  
  local result
  result=$(isDeployed "infra" "$INFRA_NAMESPACE" "mysql-0")
  
  if [[ "$result" == "true" ]]; then
      if [[ "$redeploy" == "false" ]]; then
          echo "    Infrastructure is already deployed. Skipping deployment."
          return 0
      else
          deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
      fi
  fi

  echo "DEBUG Creating namespace $INFRA_NAMESPACE for infrastructure"
  createNamespace "$INFRA_NAMESPACE"
  check_command_execution $? "createNamespace $INFRA_NAMESPACE"

  # Update helm dependencies for infra chart
  printf "    Updating dependencies for infra helm chart "
  run_as_user "cd $INFRA_CHART_DIR && helm dep update" >> /dev/null 2>&1
  check_command_execution $? "helm dep update for infra chart"
  echo " [ok] "

  # Deploy infra helm chart
  printf "    Deploying infra helm chart  "
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
    check_command_execution $? "deployHelmChartFromDir infra"
  else 
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
    check_command_execution $? "deployHelmChartFromDir infra"
  fi
  echo " [ok] "
  
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

    if [ ! -d "$directory" ]; then
        echo "Error: Directory '$directory' not found."
        return 1
    fi

    # Apply persistence-related manifests first
    for file in "$directory"/*persistence*.yaml; do
      if [ -f "$file" ]; then
        run_as_user "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        check_command_execution $? "kubectl apply -f $file -n $namespace"
      fi
    done

    # Apply other manifests
    for file in "$directory"/*.yaml; do
      if [[ "$file" != *persistence*.yaml && -f "$file" ]]; then
        run_as_user "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        check_command_execution $? "kubectl apply -f $file -n $namespace"
      fi
    done
}

function addKubeConfig() {
  local K8sConfigDir="$k8s_user_home/.kube"

  if [ ! -d "$K8sConfigDir" ]; then
      run_as_user "mkdir -p $K8sConfigDir"
      check_command_execution $? "mkdir -p $K8sConfigDir"
      echo "K8sConfigDir created: $K8sConfigDir"
  else
      echo "K8sConfigDir already exists: $K8sConfigDir"
  fi
  
  run_as_user "cp $k8s_user_home/k3s.yaml $K8sConfigDir/config"
  check_command_execution $? "cp $k8s_user_home/k3s.yaml $K8sConfigDir/config"
}

function test_vnext() {
  echo "TODO" #TODO Write function to test apps
}

function test_phee() {
  echo "TODO"
}

function test_mifosx() {
  local instance_name=$1
  # TODO: Implement testing logic
}

function printEndMessage() {
  cat << EOF

=================================
Thank you for using Mifos Gazelle
=================================

CHECK DEPLOYMENTS USING kubectl
kubectl get pods -n vnext         # For testing mojaloop vNext
kubectl get pods -n paymenthub    # For testing PaymentHub EE
kubectl get pods -n mifosx        # For testing MifosX

or install k9s by executing ./src/utils/install-k9s.sh in this terminal window

EOF
}

function deleteApps() {
  local appsToDelete="$2"

  if [[ "$appsToDelete" == "all" ]]; then
    echo "Deleting all applications and related resources."
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "default"
    return 0
  fi

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
        exit 1
        ;;
    esac
  done
}

function deployApps() {
  local appsToDeploy="$2"
  local redeploy="${3:-false}"
  
  echo "Redeploy mode: $redeploy"
  echo -e "${BLUE}Starting deployment for applications: $appsToDeploy...${RESET}"

  # Special handling for 'all' as a block-deploy
  if [[ "$appsToDeploy" == "all" ]]; then
    echo -e "${BLUE}Deploying all apps...${RESET}"
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
          deployInfrastructure "$redeploy"
          ;;
        "vnext")
          deployInfrastructure "false"
          deployvNext
          ;;
        "mifosx")
          if [[ "$redeploy" == "true" ]]; then 
            echo "Removing current mifosx and redeploying"
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