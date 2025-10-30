#!/bin/bash

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in 
export RUN_DIR 
#source "$RUN_DIR/src/commandline/commandline.sh" 

# Source commandline.sh
source "$RUN_DIR/src/commandline/commandline.sh"

# Call main with all arguments
main "$@"