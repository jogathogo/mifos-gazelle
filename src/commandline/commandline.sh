#!/usr/bin/env bash

source "$RUN_DIR/src/configurationManager/config.sh"
source "$RUN_DIR/src/environmentSetup/environmentSetup.sh"
source "$RUN_DIR/src/deployer/deployer.sh"

# Detect OS
OS_TYPE="$(uname -s)"
case "${OS_TYPE}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS_TYPE}"
esac

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
        if [[ "$MACHINE" == "Mac" ]]; then
            # On macOS, use pip to install crudini
            if ! command -v pip3 &> /dev/null; then
                logWithLevel "$ERROR" "pip3 not found. Please install Python 3 and pip3 first."
                exit 1
            fi
            pip3 install crudini
        elif command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y crudini
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y crudini
        elif command -v yum &> /dev/null; then
            sudo yum install -y crudini
        else
            logWithLevel "$ERROR" "Package manager not found. Please install crudini manually."
            exit 1
        fi
        if ! command -v crudini &> /dev/null; then
            logWithLevel "$ERROR" "Failed to install crudini. Exiting."
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
k8s_user_version="1.33"
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

    # Read [environment] section
    local config_k8s_user=$(crudini --get "$config_path" environment user 2>/dev/null)
    if [[ -n "$config_k8s_user" ]]; then
        if [[ "$config_k8s_user" == "\$USER" || "$config_k8s_user" == '$USER' ]]; then
            k8s_user="$(resolve_invoker_user)"
            logWithLevel "$INFO" "Expanded '\$USER' in config to invoking username: $k8s_user"
        else
            k8s_user="$config_k8s_user"
        fi
    fi

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

# INFO: New additions are till here

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

# INFO: Script Updation starts from here

function showUsage {
    echo "
    USAGE: $0 [-f <config_file_path>] -m [mode] -u [user] -a [apps] -e [environment] -d [true/false]
    Example 1 : sudo $0 -m deploy -u \$USER -d true          # install mifos-gazelle with debug mode and user \$USER
    Example 2 : sudo $0 -m cleanapps -u \$USER -d true        # delete apps, leave environment with debug mode and user \$USER
    Example 3 : sudo $0 -m cleanall -u \$USER                 # delete all apps, all Kubernetes artifacts, and server
    Example 4 : sudo $0 -m deploy -u \$USER -a phee           # install PHEE only, user \$USER
    Example 5 : sudo $0 -m deploy -u \$USER -a all            # install all core apps (vNext, PHEE, and MifosX) with user \$USER
    Example 6 : sudo $0 -m deploy -u \$USER -a \"mifosx,vnext\" # install MifosX and vNext
    Example 7 : sudo $0 -f /opt/my_config.ini                 # Use a custom config file

    Options:
    -f config_file_path .. Specify an alternative config.ini file path (optional)
    -m mode ................ deploy|cleanapps|cleanall  (required)
    -u user ................ (non root) user that the process will use for execution (required)
    -a apps ................ Comma-separated list of apps (vnext,phee,mifosx,infra) or 'all' (optional)
    -d debug ............... enable debug mode (true|false) (optional default=false)
    -r redeploy ............ force redeployment of apps (true|false) (optional, default=true)
    -h|H ................... display this message
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
        local CORE_APPS="vnext phee mifosx"

        # Iterate through each app specified in the 'apps' variable
        local current_apps_array
        IFS=' ' read -r -a current_apps_array <<< "$apps"

        local found_all_keyword="false"
        local specific_apps_count=0

        for app_item in "${current_apps_array[@]}"; do
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

    environment="${environment:-local}"
    debug="${debug:-false}"
    redeploy="${redeploy:-true}"
}

# Function to parse command-line options into an associative array
function getOptions() {
    local -n options_map=$1
    shift

    OPTIND=1
    while getopts "m:k:d:a:v:u:r:f:hH" OPTION ; do
        case "${OPTION}" in
            f) options_map["config_file_path"]="${OPTARG}" ;;
            m) options_map["mode"]="${OPTARG}" ;;
            k) options_map["k8s_distro"]="${OPTARG}" ;;
            d) options_map["debug"]="${OPTARG}" ;;
            a) options_map["apps"]="${OPTARG}" ;; 
            v) options_map["k8s_user_version"]="${OPTARG}" ;;
            u) options_map["k8s_user"]="${OPTARG}" ;;
            r) options_map["redeploy"]="${OPTARG}" ;;
            h|H) showUsage;
                 exit 0 ;;
            *) echo "Unknown option: -${OPTION}"
               showUsage;
               exit 1 ;;
        esac
    done
}

# this function is called when Ctrl-C is sent
function cleanUp ()
{
    echo -e "${RED}Performing graceful clean up${RESET}"
    mode="cleanup"
    echo "exiting via cleanUp function" 
    exit 2
}

function trapCtrlc {
  echo
  echo -e "${RED}Ctrl-C caught...${RESET}"
  cleanUp
}

# initialise trap to call trap_ctrlc function
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

    # Determine the configuration file path
    if [[ -n "${cmd_args_map["config_file_path"]}" ]]; then
        CONFIG_FILE_PATH="${cmd_args_map["config_file_path"]}"
    fi
    logWithLevel "$INFO" "Using config file: $CONFIG_FILE_PATH"

    # Load configuration from the file
    loadConfigFromFile "$CONFIG_FILE_PATH"

    # Merge command-line arguments
    if [[ -n "${cmd_args_map["mode"]}" ]]; then mode="${cmd_args_map["mode"]}"; fi
    if [[ -n "${cmd_args_map["k8s_user"]}" ]]; then k8s_user="${cmd_args_map["k8s_user"]}"; fi
    if [[ -n "${cmd_args_map["apps"]}" ]]; then
        apps=$(echo "${cmd_args_map["apps"]}" | tr ',' ' ')
        logWithLevel "$INFO" "CLI apps converted to space-separated: $apps"
    fi
    if [[ -n "${cmd_args_map["debug"]}" ]]; then debug="${cmd_args_map["debug"]}"; fi
    if [[ -n "${cmd_args_map["redeploy"]}" ]]; then redeploy="${cmd_args_map["redeploy"]}"; fi
    if [[ -n "${cmd_args_map["k8s_distro"]}" ]]; then k8s_distro="${cmd_args_map["k8s_distro"]}"; fi
    if [[ -n "${cmd_args_map["k8s_user_version"]}" ]]; then k8s_user_version="${cmd_args_map["k8s_user_version"]}"; fi

    # Validate and set final defaults for all variables
    validateInputs

    # Main execution logic
    if [ "$mode" == "deploy" ]; then
        echo -e "${YELLOW}"
        echo -e "======================================================================================================"
        echo -e "The deployment made by this script is currently recommended for demo, test and educational purposes "
        echo -e "======================================================================================================"
        echo -e "${RESET}"
        envSetupMain "$mode" "$k8s_distro" "$k8s_user_version" "$environment"
        deployApps "$mifosx_instances" "$apps" "$redeploy"
    elif [ "$mode" == "cleanapps" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Cleaning up Mifos Gazelle applications only"
        deleteApps "$mifosx_instances" "$apps"
    elif [ "$mode" == "cleanall" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Cleaning up all traces of Mifos Gazelle "
        deleteApps "$mifosx_instances" "all"
        envSetupMain "$mode" "$k8s_distro" "$k8s_user_version" "$environment"
    else
        showUsage
    fi
}

###########################################################################
# CALL TO MAIN
###########################################################################
main "$@"