#!/usr/bin/env bash

source "$RUN_DIR/src/configurationManager/config.sh"
source "$RUN_DIR/src/environmentSetup/environmentSetup.sh"
source "$RUN_DIR/src/deployer/deployer.sh"

# INFO: New additions start from here
DEFAULT_CONFIG_FILE="$RUN_DIR/config/config.ini"

# Resolve invoking user robustly (handles sudo)
resolve_invoker_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi
  if invoker="$(logname 2>/dev/null)"; then
    [[ -n "$invoker" ]] && printf '%s\n' "$invoker" && return
  fi
  if [[ -n "${LOGNAME:-}" && "${LOGNAME}" != "root" ]]; then
    printf '%s\n' "$LOGNAME"
    return
  fi
  whoami
}

function install_crudini() {
    if ! command -v crudini &> /dev/null; then
        logWithLevel "$INFO" "crudini not found. Attempting to install..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y crudini
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y crudini
        elif command -v yum &> /dev/null; then
            sudo yum install -y crudini
        else
            logWithLevel "$ERROR" "Neither apt-get, dnf, nor yum found. Please install crudini manually."
            exit 1
        fi
        if ! command -v crudini &> /dev/null; then
            logWithLevel "$ERROR" "Failed to install crudini. Exiting."
            exit 1
        fi
        logWithLevel "$INFO" "crudini installed successfully."
    fi
}

# Global variables that will hold the final configuration.
mode=""
k8s_user=""
apps=""
environment="local"
debug="false"
redeploy="true"
k8s_distro="k3s"
k8s_user_version="1.32"
kubeconfig_path=""
CONFIG_FILE_PATH="$DEFAULT_CONFIG_FILE"

# Function to load configuration from the INI file using crudini
# This function populates the global configuration variables directly.
function loadConfigFromFile() {
    local config_path="$1"
    logWithLevel "$INFO" "Attempting to load configuration from $config_path using crudini."

    if [ ! -f "$config_path" ]; then
        logWithLevel "$WARNING" "Configuration file not found: $config_path. Proceeding with defaults and command-line arguments."
        return 0
    fi

    # Read [general] section
    local config_mode=$(crudini --get "$config_path" general mode 2>/dev/null)
    if [[ -n "$config_mode" ]]; then mode="$config_mode"; fi
    local config_gazelle_domain=$(crudini --get "$config_path" general GAZELLE_DOMAIN 2>/dev/null)
    if [[ -n "$config_gazelle_domain" ]]; then GAZELLE_DOMAIN="$config_gazelle_domain"; fi

    # Read [kubernetes] section
    local config_environment=$(crudini --get "$config_path" kubernetes environment 2>/dev/null)
    if [[ -n "$config_environment" ]]; then environment="$config_environment"; fi
    local config_k8s_distro=$(crudini --get "$config_path" kubernetes k8s_distro 2>/dev/null)
    if [[ -n "$config_k8s_distro" ]]; then k8s_distro="$config_k8s_distro"; fi
    local config_k8s_version=$(crudini --get "$config_path" kubernetes k8s_version 2>/dev/null)
    if [[ -n "$config_k8s_version" ]]; then k8s_user_version="$config_k8s_version"; fi
    local config_k8s_user=$(crudini --get "$config_path" kubernetes k8s_user 2>/dev/null)
    if [[ -n "$config_k8s_user" ]]; then
        if [[ "$config_k8s_user" == "\$USER" || "$config_k8s_user" == '$USER' ]]; then
            k8s_user="$(resolve_invoker_user)"
            logWithLevel "$INFO" "Expanded '\$USER' in config to invoking username: $k8s_user"
        else
            k8s_user="$config_k8s_user"
        fi
    fi
    local config_kubeconfig_path=$(crudini --get "$config_path" kubernetes kubeconfig_path 2>/dev/null)
    echo "Config kubeconfig_path from file: $config_kubeconfig_path"
    if [[ -n "$config_kubeconfig_path" ]]; then
        if [[ "$config_kubeconfig_path" == "~/.kube/config" ]]; then
            k8s_user_home=$(eval echo "~$k8s_user")
            kubeconfig_path="$k8s_user_home/.kube/config"
        else
            kubeconfig_path="$config_kubeconfig_path"
        fi
    fi
    echo "DEBUG Config kubeconfig_path from file: $config_kubeconfig_path"
    # Read app enablement flags and construct the 'apps' variable
    local enabled_apps_list=""
    local valid_apps=("infra" "vnext" "phee" "mifosx")

    for app_name in "${valid_apps[@]}"; do
        local app_enabled=$(crudini --get "$config_path" "$app_name" enabled 2>/dev/null)
        app_enabled=$(echo "$app_enabled" | tr '[:upper:]' '[:lower:]')
        if [[ "$app_enabled" == "true" ]]; then
            enabled_apps_list+=" $app_name"
            logWithLevel "$INFO" "Config indicates '$app_name' is enabled."
        fi
    done
    apps=$(echo "$enabled_apps_list" | xargs)

    # Override supported global variables from config.ini
    declare -A override_map=(
        [general]="GAZELLE_DOMAIN GAZELLE_VERSION"
        [mysql]="MYSQL_SERVICE_NAME MYSQL_SERVICE_PORT LOCAL_PORT MAX_WAIT_SECONDS MYSQL_HOST"
        [infra]="INFRA_NAMESPACE INFRA_RELEASE_NAME"
        [vnext]="VNEXTBRANCH VNEXTREPO_DIR VNEXT_NAMESPACE VNEXT_REPO_LINK"
        [phee]="PHBRANCH PHREPO_DIR PH_NAMESPACE PH_RELEASE_NAME PH_REPO_LINK PH_EE_ENV_TEMPLATE_REPO_LINK PH_EE_ENV_TEMPLATE_REPO_BRANCH PH_EE_ENV_TEMPLATE_REPO_DIR"
        [mifosx]="MIFOSX_NAMESPACE MIFOSX_REPO_DIR MIFOSX_BRANCH MIFOSX_REPO_LINK"
    )

    for section in "${!override_map[@]}"; do
        for var_name in ${override_map[$section]}; do
            value=$(crudini --get "$config_path" "$section" "$var_name" 2>/dev/null)
            if [[ -n "$value" ]]; then
                eval "$var_name=\"\$value\""
                export "$var_name"
                logWithLevel "$INFO" "Overridden from config [$section]: $var_name=$value"
            fi
        done
    done
}

function welcome {
    echo -e "${BLUE}"
    echo -e " ██████   █████  ███████ ███████ ██      ██      ███████ "
    echo -e "██       ██   ██    ███  ██      ██      ██      ██      "
    echo -e "██   ███ ███████   ███   █████   ██      ██      █████   "
    echo -e "██    ██ ██   ██  ███    ██      ██      ██      ██      "
    echo -e " ██████  ██   ██ ███████ ███████ ███████ ███████ ███████ "
    echo -e "${RESET}"
    echo -e "Mifos Gazelle - a Mifos Digital Public Infrastructure as a Solution (DaaS) deployment tool."
    echo -e "                deploying MifosX, PaymentHub EE and vNext on Kubernetes."
    echo -e "Version: $GAZELLE_VERSION"
    echo
}

function showUsage {
    echo "
    USAGE: $0 [-f <config_file_path>] -m [mode] -u [user] -a [apps] -k [k8s_distro] -v [k8s_version] -e [environment] -d [true/false] -r [true/false]
    Example 1 : sudo $0 -m deploy -u \$USER -d true          # install mifos-gazelle with debug mode and user \$USER
    Example 2 : sudo $0 -m cleanapps -u \$USER -d true       # delete apps, leave environment with debug mode and user \$USER
    Example 3 : sudo $0 -m cleanall -u \$USER                # delete all apps, all Kubernetes artifacts, and server
    Example 4 : sudo $0 -m deploy -u \$USER -a phee          # install PHEE only, user \$USER
    Example 5 : sudo $0 -m deploy -u \$USER -a all           # install all core apps (vNext, PHEE, and MifosX) with user \$USER
    Example 6 : sudo $0 -m deploy -u \$USER -a \"mifosx,vnext\" # install MifosX and vNext
    Example 7 : sudo $0 -f /opt/my_config.ini                # Use a custom config file

    Options:
    -f config_file_path .. Specify an alternative config.ini file path (optional)
    -m mode .............. deploy|cleanapps|cleanall (required)
    -u user .............. (non root) user that the process will use for execution (required)
    -a apps .............. Comma-separated list of apps (vnext,phee,mifosx,infra) or 'all' (optional)
    -k k8s_distro ........ Kubernetes distribution for local clusters (k3s or microk8s, optional)
    -v k8s_version ....... Kubernetes version for local clusters (e.g., 1.31, optional)
    -e environment ....... Cluster environment (local or remote, optional, default=local)
    -d debug ............. Enable debug mode (true|false, optional, default=false)
    -r redeploy .......... Force redeployment of apps (true|false, optional, default=true)
    -h|H ................. Display this message
    "
}

function validateInputs {
    if [[ -z "$mode" || -z "$k8s_user" ]]; then
        echo "Error: Required options -m (mode) and -u (user) must be provided."
        showUsage
        exit 1
    fi

    if [[ "$mode" != "deploy" && "$mode" != "cleanapps" && "$mode" != "cleanall" ]]; then
        echo "Error: Invalid mode '$mode'. Must be one of: deploy, cleanapps, cleanall."
        showUsage
        exit 1
    fi

    if [[ "$mode" == "deploy" || "$mode" == "cleanapps" ]]; then
        if [[ -z "$apps" ]]; then
            echo "No specific apps provided with -a flag or config file. Defaulting to 'all'."
            apps="all"
        fi

        # Define valid individual applications
        local ALL_VALID_APPS="infra vnext phee mifosx all"
        local CORE_APPS="vnext phee mifosx" # Apps that 'all' refers to

        # Iterate through each app specified in the 'apps' variable
        local current_apps_array
        IFS=' ' read -r -a current_apps_array <<< "$apps" # Convert space-separated string to array

        local found_all_keyword="false"
        local specific_apps_count=0

        for app_item in "${current_apps_array[@]}"; do
            # Check if the individual app_item is valid
            if ! [[ " $ALL_VALID_APPS " =~ " $app_item " ]]; then
                echo "Error: Invalid app specified: '$app_item'. Must be one of: ${ALL_VALID_APPS// /, }."
                showUsage
                exit 1
            fi

            if [[ "$app_item" == "all" ]]; then
                found_all_keyword="true"
            else
                ((specific_apps_count++))
            fi
        done

        # Handle 'all' keyword conflicts
        if [[ "$found_all_keyword" == "true" ]]; then
            if [[ "$specific_apps_count" -gt 0 ]]; then
                echo "Error: Cannot combine 'all' with specific applications. If 'all' is specified, no other apps should be listed."
                showUsage
                exit 1
            fi
            # If 'all' is present and valid, expand it to the full list of core apps
            apps="$CORE_APPS"
            logWithLevel "$INFO" "Expanded 'all' keyword to: $apps"
        fi
    fi

    if [[ -n "$debug" && "$debug" != "true" && "$debug" != "false" ]]; then
        echo "Error: Invalid value for debug. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$redeploy" && "$redeploy" != "true" && "$redeploy" != "false" ]]; then
        echo "Error: Invalid value for redeploy. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$environment" && "$environment" != "local" && "$environment" != "remote" ]]; then
        echo "Error: Invalid environment '$environment'. Must be 'local' or 'remote'."
        showUsage
        exit 1
    fi

    if [[ "$environment" == "local" ]]; then
        if [[ -n "$k8s_distro" && "$k8s_distro" != "k3s" && "$k8s_distro" != "microk8s" ]]; then
            echo "Error: Invalid k8s_distro '$k8s_distro'. Must be 'k3s' or 'microk8s' for local environment."
            showUsage
            exit 1
        fi
        if [[ -z "$k8s_distro" ]]; then
            echo "Error: k8s_distro must be specified for local environment."
            showUsage
            exit 1
        fi
        if [[ -z "$k8s_user_version" ]]; then
            echo "Error: k8s_version must be specified for local environment."
            showUsage
            exit 1
        fi
    fi

    if [[ "$environment" == "remote" && -n "$kubeconfig_path" && ! -f "$kubeconfig_path" ]]; then
        echo "Error: kubeconfig_path '$kubeconfig_path' does not exist or is not a file."
        showUsage
        exit 1
    fi

    # Set final defaults if they haven't been set by config or command line
    environment="${environment:-local}"
    debug="${debug:-false}"
    redeploy="${redeploy:-true}"
    k8s_distro="${k8s_distro:-k3s}"
    k8s_user_version="${k8s_user_version:-1.32}"
    if [[ "$environment" == "remote" && -z "$kubeconfig_path" ]]; then
        k8s_user_home=$(eval echo "~$k8s_user")
        kubeconfig_path="$k8s_user_home/.kube/config"
        logWithLevel "$INFO" "No kubeconfig_path specified in config.ini for remote environment. Defaulting to $kubeconfig_path"
    fi
}

# Function to parse command-line options into an associative array
function getOptions() {
    local -n options_map=$1 # Use nameref to pass array by reference (Bash 4.3+)
    shift # Shift past the array name argument

    OPTIND=1 # Reset getopts index for fresh parsing
    while getopts "m:k:d:a:v:u:r:f:e:hH" OPTION ; do
        case "${OPTION}" in
            f) options_map["config_file_path"]="${OPTARG}" ;;
            m) options_map["mode"]="${OPTARG}" ;;
            k) options_map["k8s_distro"]="${OPTARG}" ;;
            d) options_map["debug"]="${OPTARG}" ;;
            a) options_map["apps"]="${OPTARG}" ;;
            v) options_map["k8s_user_version"]="${OPTARG}" ;;
            u) options_map["k8s_user"]="${OPTARG}" ;;
            r) options_map["redeploy"]="${OPTARG}" ;;
            e) options_map["environment"]="${OPTARG}" ;;
            h|H) showUsage;
                 exit 0 ;;
            *) echo "Unknown option: -${OPTION}"
               showUsage;
               exit 1 ;;
        esac
    done
}

# This function is called when Ctrl-C is sent
function cleanUp() {
    echo -e "${RED}Performing graceful clean up${RESET}"
    mode="cleanall"
    echo "Exiting via cleanUp function"
    envSetupMain "$mode" "$k8s_distro" "$k8s_user_version" "$environment" "$kubeconfig_path"
    exit 2
}

function trapCtrlc {
    echo
    echo -e "${RED}Ctrl-C caught...${RESET}"
    cleanUp
}

# Initialise trap to call trap_ctrlc function when signal 2 (SIGINT) is received
trap "trapCtrlc" 2

###########################################################################
# MAIN
###########################################################################
function main {
    welcome
    install_crudini

    # Declare an associative array to store command-line arguments
    declare -A cmd_args_map
    getOptions cmd_args_map "$@"

    # Determine the configuration file path: CLI override first, then default
    if [[ -n "${cmd_args_map["config_file_path"]}" ]]; then
        CONFIG_FILE_PATH="${cmd_args_map["config_file_path"]}"
    fi
    logWithLevel "$INFO" "Using config file: $CONFIG_FILE_PATH"

    # Load configuration from the file
    loadConfigFromFile "$CONFIG_FILE_PATH"

    # Merge command-line arguments, giving them precedence over config file values
    if [[ -n "${cmd_args_map["mode"]}" ]]; then mode="${cmd_args_map["mode"]}"; fi
    if [[ -n "${cmd_args_map["k8s_user"]}" ]]; then k8s_user="${cmd_args_map["k8s_user"]}"; fi
    if [[ -n "${cmd_args_map["apps"]}" ]]; then
        # Convert comma-separated to space-separated
        apps=$(echo "${cmd_args_map["apps"]}" | tr ',' ' ')
        logWithLevel "$INFO" "CLI apps converted to space-separated: $apps"
    fi
    if [[ -n "${cmd_args_map["debug"]}" ]]; then debug="${cmd_args_map["debug"]}"; fi
    if [[ -n "${cmd_args_map["redeploy"]}" ]]; then redeploy="${cmd_args_map["redeploy"]}"; fi
    if [[ -n "${cmd_args_map["k8s_distro"]}" ]]; then k8s_distro="${cmd_args_map["k8s_distro"]}"; fi
    if [[ -n "${cmd_args_map["k8s_user_version"]}" ]]; then k8s_user_version="${cmd_args_map["k8s_user_version"]}"; fi
    if [[ -n "${cmd_args_map["environment"]}" ]]; then environment="${cmd_args_map["environment"]}"; fi

    # Validate and set final defaults for all variables
    validateInputs

    # Main execution logic based on the final determined variables
    if [ "$mode" == "deploy" ]; then
        echo -e "${YELLOW}"
        echo -e "======================================================================================================"
        echo -e "The deployment made by this script is currently recommended for demo, test and educational purposes "
        echo -e "======================================================================================================"
        echo -e "${RESET}"
        envSetupMain "$mode" "$k8s_distro" "$k8s_user_version" "$environment" "$k8s_user" "$kubeconfig_path"
        deployApps "$mifosx_instances" "$apps" "$redeploy"
    elif [ "$mode" == "cleanapps" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Cleaning up Mifos Gazelle applications only"
        deleteApps "$mifosx_instances" "$apps"
    elif [ "$mode" == "cleanall" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Cleaning up all traces of Mifos Gazelle "
        deleteApps "$mifosx_instances" "all"
        envSetupMain "$mode" "$k8s_distro" "$k8s_user_version" "$environment" "$k8s_user" "$kubeconfig_path"
    else
        showUsage
        exit 1
    fi
}

###########################################################################
# CALL TO MAIN
###########################################################################
main "$@"