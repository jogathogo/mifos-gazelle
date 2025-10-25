#!/usr/bin/env bash
# helpers.sh -- Shared utility functions for Mifos Gazelle deployment

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file and should not be executed directly. Source it from another script."
    exit 1
fi

function check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        printf "** Error: This script must be run with sudo or as root user ** \n"
        exit 1
    fi
}

# Run a command as the non-root k8s_user with KUBECONFIG set
run_as_user() {
    local command="$1"
    logWithVerboseCheck "$debug" debug "Running as $k8s_user: $command"
    su - "$k8s_user" -c "export KUBECONFIG=$kubeconfig_path; $command"
    return $exit_code
    # TODO tidy this up 
    #local exit_code=$?

    # if [[ $exit_code -ne 0 ]]; then
    #     #printf "  ** Error: Command failed when running as user %s: %s ** \n" "$k8s_user" "$command"
    #     logWithVerboseCheck "$debug" error "Command failed: $command"
    #     #exit $exit_code
    # fi
}

# Check if a command executed successfully
function check_command_execution() {
    echo "DEBUG: check_command_execution called with exit_code=$1, cmd=$2"
    local exit_code=$1
    local cmd="$2"
    if [[ $exit_code -ne 0 ]]; then
        echo "  ** Error: Command execution failed: $cmd ** "
        logWithVerboseCheck "$debug" error "Failed to execute: $cmd"
        exit $exit_code
    fi
    echo "  ** Error: Command execution failed: $cmd ** "
    logWithVerboseCheck "$debug" debug "Successfully executed: $cmd"
}

# Debug function to check if a function exists
function function_exists() {
    declare -f "$1" > /dev/null
    return $?
}

