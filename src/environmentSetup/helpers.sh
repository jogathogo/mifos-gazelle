#!/usr/bin/env bash
# helper functions for OS and kubernetes environment setup

# function run_as_user { 
#     su - "$k8s_user" -c "export KUBECONFIG=$kubeconfig_path; $1"; 
# }

function check_arch_ok {
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "arm64" && "$arch" != "aarch64" ]]; then
        printf " **** Error Unknown CPU architecture : mifos-gazelle only works properly with x86_64, arm64, or aarch64 architectures today  *****\n"
        exit 1 
    fi
}

function check_resources_ok {
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    free_space=$(df -BG ~ | awk '{print $4}' | tail -n 1 | sed 's/G//')
    if [[ "$total_ram" -lt "$MIN_RAM" ]]; then
        printf " ** Error: mifos-gazelle currently requires $MIN_RAM GBs to run properly \n"
        printf "    Please increase RAM available before trying to run mifos-gazelle \n"
        exit 1
    fi
    if [[ "$free_space" -lt "$MIN_FREE_SPACE" ]] ; then
        printf " ** Warning: mifos-gazelle currently requires %sGBs free storage in %s home directory  \n" "$MIN_FREE_SPACE" "$k8s_user"
        printf "    but only found %sGBs free storage \n" "$free_space"
        printf "    mifos-gazelle installation will continue, but beware it might fail later due to insufficient storage \n"
    fi
}

function set_linux_os_distro {
    LINUX_VERSION="Unknown"
    if [ -x "/usr/bin/lsb_release" ]; then
        LINUX_OS=`lsb_release --d | perl -ne 'print if s/^.*Ubuntu.*(\d+).(\d+).*$/Ubuntu/' `
        LINUX_VERSION=`/usr/bin/lsb_release --d | perl -ne 'print $& if m/(\d+)/' `
    else
        LINUX_OS="Untested"
    fi
    printf "\r==> Linux OS is [%s] " "$LINUX_OS"
}


function check_os_ok {
    printf "\r==> checking OS and kubernetes distro is tested with mifos-gazelle scripts\n"
    set_linux_os_distro
    if [[ ! $LINUX_OS == "Ubuntu" ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu OS at this time   **\n"
        exit 1
    fi
    echo "    Linux OS distro is $LINUX_OS version $LINUX_VERSION"
    echo "    Supported Ubuntu versions are: ${ubuntu_ok_versions_list[*]}"
    if [[ ! " ${ubuntu_ok_versions_list[*]} " =~ " ${LINUX_VERSION} " ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu this time   **\n"
        exit 1
    fi
}

function verify_user {
    if [ -z ${k8s_user+x} ]; then
        printf "** Error: The operating system user has not been specified with the -u flag \n"
        printf "          the user specified with the -u flag must exist and not be the root user \n"
        printf "** \n"
        exit 1
    fi
    if [[ `id -u $k8s_user >/dev/null 2>&1; echo $?` == 0 ]]; then
        if [[ `id -u $k8s_user` == 0 ]]; then
            printf "** Error: The user specified by -u should be a non-root user ** \n"
            exit 1
        fi
    else
        printf "** Error: The user [ %s ] does not exist in the operating system \n" "$k8s_user"
        printf "            please try again and specify an existing user \n"
        printf "** \n"
        exit 1
    fi
    k8s_user_home=`eval echo "~$k8s_user"`
}

# check which kubernetes related tools are installed 
function checkTools {
    # Set the default tools to check (helm and kubectl)
    local tools=("helm" "kubectl")

    # If arguments are provided, use them instead of the default list
    if [ "$#" -gt 0 ]; then
        tools=("$@")
    fi

    # Loop through the list of tools and check each one
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            echo "Error: '$tool' is not installed. Check failed." >&2
            return 1 # Return 1 (failure) without exiting the script
        fi
    done

    return 0 # Return 0 (success) if all tools were found
}

function is_local_k8s_already_installed () {
    if [[ -f /usr/local/bin/k3s ]]; then
        echo "local Kubernetes Cluster (k3s) is installed."
        return 0 # Success
    else
        return 1 # Failure
    fi
}




# function is_local_k8s_already_installed {
#     if [[ -f "/usr/local/bin/k3s" ]]; then
#         printf "==> k3s is already installed **\n"
#         return 0
#     fi
#     return 1
# }

