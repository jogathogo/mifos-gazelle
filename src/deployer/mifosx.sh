#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X 

#------------------------------------------------------------------------------
# Function: DeployMifosXfromYaml
# Description: Deploys MifosX (Fineract + web app) using Kubernetes manifests from a specified directory.
# Parameters:
#   $1 - Directory containing the Kubernetes manifests for MifosX deployment.
#   $2 - (Optional) Timeout in seconds to wait for the fineract-server pod to be ready. Default is 600 seconds.
#------------------------------------------------------------------------------
function DeployMifosXfromYaml() {
    manifests_dir=$1
    timeout_secs=${2:-600}  # Default timeout of 10 minutes if not specified

    if is_app_running  "$MIFOSX_NAMESPACE"; then
      if [[ "$redeploy" == "false" ]]; then
        echo "    MifosX application is already deployed. Skipping deployment."
        return
      fi
    fi 
    # We are deploying or redeploying => make sure things are cleaned up first
    printf "    Redeploying MifosX : Deleting existing resources in namespace %s\n" "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    echo "==> Deploying MifosX i.e. web-app and fineract via application manifests"
    createNamespace "$MIFOSX_NAMESPACE"
    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"
    
    # Update FQDNs in values file and manifests
    echo "    Updating MifosX FQDNs manifest(s) to use domain $GAZELLE_DOMAIN"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 

    # Restore the database dump before starting MifosX
    # Assumes FINERACT_LIQUIBASE_ENABLED=false in fineract deployment
    echo "    Restoring MifosX database dump "
    run_as_user "$UTILS_DIR/dump-restore-fineract-db.sh -r"  > /dev/null
    
    echo "    deploying MifosX manifests from $manifests_dir"
    applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    
    # Wait for fineract-server pod to be ready
    echo "    Waiting for fineract-server pod to be ready (timeout: ${timeout_secs}s)..."
    if run_as_user "kubectl wait --for=condition=Ready pod -l app=fineract-server \
        --namespace=\"$MIFOSX_NAMESPACE\" --timeout=\"${timeout_secs}s\" "  > /dev/null 2>&1 ; then
        echo "    MifosX  is  ready"
    else
        echo -e "${RED} ERROR: MifosX fineract-server pod failed to become ready within ${timeout_secs} seconds ${RESET}"
        return 1
    fi  
    echo -e "\n${GREEN}====================================="
    echo -e "MifosX (fineract + web app) Deployed"
    echo -e "=====================================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function : generateMifosXandVNextData
# Description: Generates MifosX clients and accounts & registers associations with vNext Oracle.
# Parameters: None
#------------------------------------------------------------------------------
function generateMifosXandVNextData {  
  local timeout=300  # 5 minutes in seconds
  local recheck_time=30  # 30 seconds
  local start_time=$(date +%s)
  local elapsed=0
  
  while [[ $elapsed -lt $timeout ]]; do
    is_app_running "vnext"
    result_vnext=$?
    is_app_running "mifosx"
    result_mifosx=$?
    
    if [[ $result_vnext -eq 0 ]] && [[ $result_mifosx -eq 0 ]]; then
      echo -e "${BLUE}    Generating MifosX clients and accounts & registering associations with vNext Oracle ...${RESET}"
      run_as_user "$RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c \"$CONFIG_FILE_PATH\" " #> /dev/null 2>&1
      
      if [[ "$?" -ne 0 ]]; then
        echo -e "${RED}Error generating vNext clients and accounts ${RESET}"
        echo " run $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c $CONFIG_FILE_PATH to investigate"
        return 1 
      fi
      
      # Success - exit the function
      return 0
    else 
      elapsed=$(( $(date +%s) - start_time ))
      
      if [[ $elapsed -lt $timeout ]]; then
        echo -e "${YELLOW}vNext or MifosX is not running. Retrying in ${recheck_time} seconds... (Elapsed: ${elapsed}s / ${timeout}s)${RESET}"
        sleep $recheck_time
        elapsed=$(( $(date +%s) - start_time ))
      fi
    fi
  done
  
  # Timeout reached
  echo -e "${RED}Timeout: vNext or MifosX did not start within ${timeout} seconds => skipping MifosX and vNext data generation ${RESET}"
  return 1
}
