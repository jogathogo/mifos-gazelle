#!/usr/bin/env bash
# helper functions for OS and kubernetes environment setup

function run_as_user { 
    su - "$k8s_user" -c "export KUBECONFIG=$kubeconfig_path; $1"; 
}

function check_arch_ok {
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "arm64" && "$arch" != "aarch64" ]]; then
        printf " **** Error: mifos-gazelle only works properly with x86_64, arm64, or aarch64 architectures today  *****\n"
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
    if [[ ! " ${UBUNTU_OK_VERSIONS_LIST[*]} " =~ " ${LINUX_VERSION} " ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu versions 22.xx or 24.xx at this time   **\n"
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

function set_user {
    logWithVerboseCheck "$debug" info "k8s user is $k8s_user"
}

