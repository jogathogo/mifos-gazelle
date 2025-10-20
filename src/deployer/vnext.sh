#!/usr/bin/env bash
# vnext.sh -- Mifos Gazelle deployer script for vNext Beta 1 switch 
function deployvNext() {
  printf "\n==> Deploying Mojaloop vNext application \n"
  
  result=$(isDeployed "vnext" "$VNEXT_NAMESPACE" "reporting-api-svc" )
  if [[ "$result" == "true" ]]; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext application is already deployed. Skipping deployment."
      return
    else # need to delete prior to redeploy 
      deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    fi
  fi 
  createNamespace "$VNEXT_NAMESPACE"
  cloneRepo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"
  # remove the TTK-CLI pod as it is not needed and comes up in error mode 
  rm  -f "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/ttk/ttk-cli.yaml" > /dev/null 2>&1
  configurevNext  # make any local mods to manifests
  vnext_restore_demo_data $CONFIG_DIR "mongodump.gz" $INFRA_NAMESPACE
  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    applyKubeManifests "$folder" "$VNEXT_NAMESPACE" #>/dev/null 2>&1
    if [ "$index" -eq 0 ]; then
      echo -e "${BLUE}    Waiting for vnext cross cutting concerns to come up${RESET}"
      sleep 10
      echo -e "    Proceeding ..."
    fi
  done
  ## don't do this by default for gazelle v1.1.0 as for v1.1.0 we now have Mifos greenbank/bluebank as much more realistic DFSPs 
  ## It is true that in for vNext or subseqent we might want TTKs for debug and testing purposes hence leaving this here for the moment
  ## vnext_configure_ttk $VNEXT_TTK_FILES_DIR  $VNEXT_NAMESPACE   # configure in the TTKs as participants 

  echo -e "\n${GREEN}============================"
  echo -e "vnext Deployed"
  echo -e "============================${RESET}\n"

}

function vnext_restore_demo_data {
  local mongo_data_dir=$1
  local mongo_dump_file=$2
  local namespace=$3 
  printf "    restoring vNext mongodb demonstration/test data "
  mongopod=`kubectl get pods --namespace $namespace | grep -i mongodb |awk '{print $1}'` 
  mongo_root_pw=`kubectl get secret --namespace $namespace  mongodb  -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}'| base64 -d` 
  if [[ -z "$mongo_root_pw" ]]; then
    echo -e "${RED}   Restore Failed to retrieve MongoDB root password from secret in namespace '$namespace'${RESET}" 
    return 1
  fi
  kubectl cp  $mongo_data_dir/$mongo_dump_file $mongopod:/tmp/mongodump.gz  --namespace $namespace  >/dev/null 2>&1 # copy the demo / test data into the mongodb pod
  # Execute mongorestore
  if ! kubectl exec --namespace "$namespace" --stdin --tty "$mongopod" -- mongorestore -u root -p "$mongo_root_pw" \
      --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin >/dev/null 2>&1; then
    echo -e "${RED}   mongorestore command failed ${RESET}" 
    return 1
  fi
  printf " [ ok ] \n"
}

function vnext_configure_ttk {
  local ttk_files_dir=$1
  local namespace=$2
  local warning_issued=false
  printf "\n==> Configuring the Testing Toolkit... "

  # Check if BlueBank pod is running => remember 
  local bb_pod_status
  bb_pod_status=$(kubectl get pods bluebank-backend-0 --namespace "$namespace" --no-headers 2>/dev/null | awk '{print $3}')
  
  if [[ "$bb_pod_status" != "Running" ]]; then
    printf "    - TTK pod is not running; skipping configuration (note TTK may not support arm64).\n"
    printf "    - Note: TTK is not essential for Mifos Gazelle deployments \n"
    return 0
  fi

  # Define TTK pod destinations
  local ttk_pod_env_dest="/opt/app/examples/environments"
  local ttk_pod_spec_dest="/opt/app/spec_files"
  
  # Function to check and report on kubectl cp command success
  check_kubectl_cp() {
    if ! kubectl cp "$1" "$2" --namespace "$namespace" 2>/dev/null; then
      printf "    [WARNING] Failed to copy %s to %s\n" "$1" "$2"
      warning_issued=true
    fi
  }
  
  # Copy BlueBank files
  check_kubectl_cp "$ttk_files_dir/environment/hub_local_environment.json" "bluebank-backend-0:$ttk_pod_env_dest/hub_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/environment/dfsp_local_environment.json" "bluebank-backend-0:$ttk_pod_env_dest/dfsp_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/user_config_bluebank.json" "bluebank-backend-0:$ttk_pod_spec_dest/user_config.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/default.json" "bluebank-backend-0:$ttk_pod_spec_dest/rules_callback/default.json"
  
  # Copy GreenBank files
  check_kubectl_cp "$ttk_files_dir/environment/hub_local_environment.json" "greenbank-backend-0:$ttk_pod_env_dest/hub_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/environment/dfsp_local_environment.json" "greenbank-backend-0:$ttk_pod_env_dest/dfsp_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/user_config_greenbank.json" "greenbank-backend-0:$ttk_pod_spec_dest/user_config.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/default.json" "greenbank-backend-0:$ttk_pod_spec_dest/rules_callback/default.json"

  # Final status message
  if [[ "$warning_issued" == false ]]; then
    printf "    [ ok ] \n"
  else
    printf "    [ WARNING ] Some files failed to copy. Check warnings above.\n"
  fi
}