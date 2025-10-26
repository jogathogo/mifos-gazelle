#!/usr/bin/env bash
# phee.sh -- Mifos Gazelle deployer script for PaymentHub EE 

function deployPH(){
  # TODO make this a global variable
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"

  if is_app_running "$PH_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    $PH_RELEASE_NAME is already deployed. Skipping deployment."
      return 0
    else # need to delete prior to redeploy 
      deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
      #deleteResourcesInNamespaceMatchingPattern "default"  #just removes prometheus at the moment and so is probably not needed
      manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
      # rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine/charts/*tgz"
      # rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle/charts/*tgz"
    fi
  fi 
  echo "==> Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  #checkPHEEDependencies
  preparePaymentHubChart
  manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  createIngressSecret "$PH_NAMESPACE" "$GAZELLE_DOMAIN" sandbox-secret
  
  # now deploy the helm chart 
  deployPhHelmChartFromDir "$PH_NAMESPACE" "$gazelleChartPath" "$PH_VALUES_FILE"
  # now load the BPMS diagrams we do it here not in the helm chart so that 
  # we can count the sucessful BPMN uploads and be confident that they are working 
  #deployBPMS
  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

function preparePaymentHubChart(){
  # Clone the repositories
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"  # needed for kibana and elastic secrets only 
  cloneRepo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"

  # Helper: choose dep build vs update
  function ensureHelmDeps() {
    local chartPath=$1
    local chartName=$(basename "$chartPath")

    echo "    ensuring dependencies for $chartName chart"
    if [[ -f "$chartPath/Chart.lock" && -s "$chartPath/Chart.lock" ]]; then
      # Count entries in Chart.lock and compare with .tgz files in charts/
      local expected=$(grep -c "name:" "$chartPath/Chart.lock")
      local actual=$(find "$chartPath/charts" -maxdepth 1 -name '*.tgz' 2>/dev/null | wc -l)

      if [[ $actual -ge $expected && $expected -gt 0 ]]; then
        #echo "      charts/ already populated ($actual/$expected) → running helm dep build"
        su - $k8s_user -c "cd $chartPath && helm dep build" >> /dev/null 2>&1
      else
        #echo "      charts/ not populated correctly ($actual/$expected) → running helm dep update"
        su - $k8s_user -c "cd $chartPath && helm dep update" >> /dev/null 2>&1
      fi
    else
      #echo "      no Chart.lock found → running helm dep update"
      su - $k8s_user -c "cd $chartPath && helm dep update" >> /dev/null 2>&1
    fi

    # Always regenerate repo index
    #su - $k8s_user -c "cd $chartPath && helm repo index ." >> /dev/null 2>&1
  }

  # Run for ph-ee-engine
  phEEenginePath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"
  ensureHelmDeps "$phEEenginePath"

  # Run for gazelle (parent)
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"
  ensureHelmDeps "$gazelleChartPath"
}

# function checkPHEEDependencies() {
#   # for Gazelle we might not need this 
#   printf "    Installing Prometheus " 
#   # Install Prometheus Operator if needed as it is a PHEE dependency
#   local deployment_name="prometheus-operator"
#   # deployment_available=$(kubectl get deployment "$deployment_name" -n "default" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' > /dev/null 2>&1)
#   deployment_available=$(kubectl get deployment "$deployment_name" -n "default" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
#   if [[ "$deployment_available" == "True" ]]; then
#     echo -e "${RED} prometheus already installed -skipping install. ${RESET}" 
#     return 0
#   fi
#   LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
#   su - $k8s_user -c "curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml | kubectl create -f - " >/dev/null 2>&1
#   if [ $? -eq 0 ]; then
#       echo " [ok] "
#   else
#       echo "   Failed to install prometheus"
#       exit 1 
#   fi
# }

function deployPhHelmChartFromDir(){
  # Parameters
  local namespace="$1"
  local chartDir="$2"      # Directory containing the Helm chart
  local valuesFile="$3"    # Values file for the Helm chart
  local releaseName="$PH_RELEASE_NAME"
  local timeout="1200s"

  # Construct install command
  local helm_cmd="helm install $releaseName $chartDir -n $namespace --wait --timeout $timeout"
  if [ -n "$valuesFile" ]; then
    helm_cmd="$helm_cmd -f $valuesFile"
    echo "    Installing Helm chart with values file: $valuesFile"
  else
    echo "    Installing Helm chart with default values..."
  fi

  # Run the install command and capture exit status
  if [ "$debug" = true ]; then
    echo "🔧 Running as $k8s_user: $helm_cmd"
    su - "$k8s_user" -c "bash -c '$helm_cmd'"
    install_exit_code=$?
  else
    output=$(su - "$k8s_user" -c "bash -c '$helm_cmd'" 2>&1)
    install_exit_code=$?
  fi

  # Verify status after install
  su - "$k8s_user" -c "helm status $releaseName -n $namespace" > /tmp/helm_status_output 2>&1
  local status_exit_code=$?

  if grep -q "^STATUS: deployed" /tmp/helm_status_output; then
    echo "    Helm release '$releaseName' deployed successfully."
    return 0
  else
    echo -e "${RED}    ❌ Helm install of release '$releaseName' has failed :${RESET}"
    exit 1
  fi
}

deployBPMS() {
  local host="https://zeebeops.mifos.gazelle.test/zeebe/upload"
  local DEBUG=false
  local successful_uploads=0
  local BPMNS_DIR="$BASE_DIR/orchestration/feel"  # BPMNs deployed from  Gazelle but probably eventually belong in ph-ee-env-template 
  local bpms_to_deploy=$(ls -l "$BPMNS_DIR"/*.bpmn | wc -l)
  printf "    Deploying BPMN diagrams from $BPMNS_DIR "

  # Find each .bpmn file in the specified directories and iterate over them
  for file in "$BPMNS_DIR"/*.bpmn;  do
    # Check if the glob expanded to an actual file or just returned the pattern
    if [ -f "$file" ]; then
      # Construct and execute the curl command for each file
      local cmd="curl --insecure --location --request POST $host \
          --header 'Platform-TenantId: greenbank' \
          --form 'file=@\"$file\"' \
          -s -o /dev/null -w '%{http_code}'"

      if [ "$DEBUG" = true ]; then
          echo "Executing: $cmd"
          http_code=$(eval "$cmd")
          exit_code=$?
          echo "HTTP Code: $http_code"
          echo "Exit code: $exit_code"
      else
          http_code=$(eval "$cmd")
          exit_code=$?
      fi 

      if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
          ((successful_uploads++))
      fi
    else
      echo -e "${RED}** Warning : No BPMN files found in $BPMNS_DIR ${RESET}" 
    fi
  done

  # Check if the number of successful uploads meets the required threshold
  if [ "$successful_uploads" -ge "$bpms_to_deploy" ]; then
    echo " [ok] "
  else
    echo -e "${RED}Warning: there was an issue deploying the BPMN diagrams."
    echo -e "         run ./src/utils/deployBpmn-gazelle.sh to investigate${RESET}"
  fi
}