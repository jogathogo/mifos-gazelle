#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X 
function DeployMifosXfromYaml() {
    manifests_dir=$1
    timeout_secs=${2:-600}  # Default timeout of 10 minutes if not specified
    echo "==> Deploying MifosX i.e. web-app and fineract via application manifests"
    createNamespace "$MIFOSX_NAMESPACE"
    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"
    
    # Restore the database dump before starting MifosX
    # Assumes FINERACT_LIQUIBASE_ENABLED=false in fineract deployment
    echo "    Restoring MifosX database dump "
    $UTILS_DIR/dump-restore-fineract-db.sh -r > /dev/null
    
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

function generateMifosXandVNextData {
  # generate load and syncronize MifosX accounts and vNext Oracle associations  
  result_vnext=$(isDeployed "vnext" "$VNEXT_NAMESPACE" "reporting-api-svc" )
  result_mifosx=$(isDeployed "mifosx" "$MIFOSX_NAMESPACE" "fineract-server" )

  if [[ "$result_vnext" == "true" ]]  && [[ "$result_mifosx" == "true" ]] ; then
    echo -e "${BLUE}Generating MifosX clients and accounts & registering associations with vNext Oracle ...${RESET}"
    $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py > /dev/null 2>&1
    if [[ "$?" -ne 0 ]]; then
      echo -e "${RED}Error generating vNext clients and accounts ${RESET}"
      echo " run $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py to investigate"
      return 1 
    fi
  else 
    echo -e "${YELLOW}vNext or MifosX is not running => skipping MifosX and vNext data generation ${RESET}"
  fi
}