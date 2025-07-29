#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Author: Benjamin Pequet
# Purpose: Unmounts the Stentor droplet's audio inbox directory from the local mount point.
# Project: https://github.com/pequet/stentor-01/
# Refer to main project for detailed docs and dependencies (fusermount, diskutil, umount).

# --- Source Utilities ---
# Resolve the true directory of this script, even if it's a symlink.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # Resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # If $SOURCE was a relative symlink, resolve it relative to the symlink's path
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
source "${SCRIPT_DIR}/../utils/logging_utils.sh"
source "${SCRIPT_DIR}/../utils/messaging_utils.sh"

# Set log file path for the logging utility
LOG_FILE_PATH="$HOME/.stentor/logs/unmount_droplet_yt.log"

# * Configuration Loading
# Determine the directory where this script is located
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf"
HOME_STENTOR_DIR="$HOME/.stentor"
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf"

CONFIG_SOURCED=false
# Try to source project-local stentor.conf file first
if [ -f "$PROJECT_ENV_FILE" ]; then
    # shellcheck source=./stentor.conf
    source "$PROJECT_ENV_FILE"
    CONFIG_SOURCED=true
    print_info "Loaded configuration from $PROJECT_ENV_FILE"
elif [ -f "$HOME_ENV_FILE" ]; then
    # shellcheck source=~/.stentor/stentor.conf
    source "$HOME_ENV_FILE"
    CONFIG_SOURCED=true
    print_info "Loaded configuration from $HOME_ENV_FILE"
else
    print_error "Configuration file (stentor.conf) not found." >&2
    print_error "Please create either $PROJECT_ENV_FILE (recommended for project-specific settings)" >&2
    print_error "OR $HOME_ENV_FILE (for global settings; you may need to create $HOME_STENTOR_DIR first)." >&2
    print_error "You can copy 'scripts/client-side/stentor_clientstentor.conf.example' to one of these locations (as stentor.conf) and populate it." >&2
    exit 1
fi

# Check for necessary variable from the stentor.conf file
if [ -z "${LOCAL_MOUNT_POINT:-}" ]; then # Check if LOCAL_MOUNT_POINT is set and not empty
    print_error "Required variable 'LOCAL_MOUNT_POINT' is not set in the sourced stentor.conf file." >&2
    print_error "Please ensure it is defined in either $PROJECT_ENV_FILE or $HOME_ENV_FILE." >&2
    exit 1
fi

# * Unmount Logic
# Expand tilde in LOCAL_MOUNT_POINT if present
eval EXPANDED_LOCAL_MOUNT_POINT="$LOCAL_MOUNT_POINT"

# Check if the mount point actually exists as a directory
if [ ! -d "$EXPANDED_LOCAL_MOUNT_POINT" ]; then
    print_info "Local mount point '$EXPANDED_LOCAL_MOUNT_POINT' does not exist. Nothing to unmount."
    exit 0
fi

# Check if mounted
if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT"; then
    print_step "Attempting to unmount: $EXPANDED_LOCAL_MOUNT_POINT"
    
    # Temporarily disable exit on error so we can handle unmount failure gracefully
    set +e
    
    if command -v fusermount &> /dev/null; then
        fusermount -u "$EXPANDED_LOCAL_MOUNT_POINT"
        UNMOUNT_EXIT_CODE=$?
    elif command -v diskutil &> /dev/null && [[ "$(uname)" == "Darwin" ]]; then # macOS specific fallback
        diskutil unmount "$EXPANDED_LOCAL_MOUNT_POINT"
        UNMOUNT_EXIT_CODE=$?
    elif command -v umount &> /dev/null; then
        umount "$EXPANDED_LOCAL_MOUNT_POINT"
        UNMOUNT_EXIT_CODE=$?
    else 
        echo "Error: No suitable unmount command found (fusermount, diskutil unmount, umount). Cannot unmount." >&2
        exit 1
    fi 
    
    # Re-enable exit on error
    set -e

    if [ $UNMOUNT_EXIT_CODE -eq 0 ]; then
        print_success "Successfully unmounted: $EXPANDED_LOCAL_MOUNT_POINT"
    else
        print_error "Failed to unmount $EXPANDED_LOCAL_MOUNT_POINT (exit code: $UNMOUNT_EXIT_CODE)"
        echo "This could be due to the mount point being busy or permission issues." >&2
        echo "Try unmounting manually:" >&2
        echo "  umount -f $EXPANDED_LOCAL_MOUNT_POINT" >&2
        echo "  fusermount -u $EXPANDED_LOCAL_MOUNT_POINT" >&2
        echo "  diskutil unmount $EXPANDED_LOCAL_MOUNT_POINT (on macOS)" >&2
        exit 1
    fi
else
    print_info "Not currently mounted at $EXPANDED_LOCAL_MOUNT_POINT. Nothing to do."
fi

exit 0 