#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Author: Benjamin Pequet
# Purpose: Configures a 2GB swap file on the system if one is not already active. Intended to be run with sudo.
# Project: https://github.com/pequet/stentor-01/
# Refer to main project for detailed docs.

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
# This script is typically run with sudo, so we log to a system-wide location.
LOG_FILE_PATH="/var/log/stentor_configure_swap.log"

print_step "Starting: Swap Configuration"

# * Swap File Check & Activation
# Check if swap is already configured to avoid errors if run multiple times
# A more robust check would be to parse `swapon --show` or `free -h`
if grep -q "/swapfile" /etc/fstab; then
    print_info "Info: /swapfile entry already exists in /etc/fstab. Verifying if active..."
    if swapon --show | grep -q "/swapfile"; then
        print_success "Completed: Swap /swapfile is already active. No changes made."
        exit 0
    else
        print_info "Info: /swapfile entry in /etc/fstab but swap is not active. Attempting to activate..."
        sudo swapon /swapfile
        if swapon --show | grep -q "/swapfile"; then
            print_success "Completed: Swap /swapfile activated successfully from existing fstab entry."
            exit 0
        else
            print_error "Failed: Could not activate /swapfile despite fstab entry. Please check manually."
            exit 1
        fi
    fi
fi

# * Swap File Creation
print_info "Info: Creating a 2GB swap file at /swapfile..."
sudo fallocate -l 2G /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to create swap file with fallocate." >&2 # Keep detailed error for sudo context
    print_error "Failed: Swap file creation (fallocate)"
    exit 1
fi

# * Swap File Permissions
print_info "Info: Securing the swap file (permissions to 600)..."
sudo chmod 600 /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to set permissions on swap file." >&2
    print_error "Failed: Swap file permissions (chmod)"
    # Attempt to clean up before exiting
    sudo rm -f /swapfile
    exit 1
fi

# * Swap Area Setup
print_info "Info: Setting up swap area on /swapfile..."
sudo mkswap /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to set up swap area with mkswap." >&2
    print_error "Failed: Swap area setup (mkswap)"
    # Attempt to clean up before exiting
    sudo rm -f /swapfile
    exit 1
fi

# * Swap Activation
print_info "Info: Enabling the swap on /swapfile..."
sudo swapon /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable swap with swapon." >&2
    print_error "Failed: Swap activation (swapon)"
    # Attempt to clean up before exiting (though mkswap was successful)
    # Reverting mkswap isn't straightforward, but we can remove the file and fstab entry if added
    sudo rm -f /swapfile 
    exit 1
fi

# * Swap Persistence (fstab)
print_info "Info: Making swap permanent by adding to /etc/fstab..."
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
if [ $? -ne 0 ]; then
    echo "Error: Failed to add swap entry to /etc/fstab." >&2
    print_error "Failed: Adding swap to /etc/fstab"
    # Attempt to disable swap and remove file as fstab entry failed
    sudo swapoff /swapfile
    sudo rm -f /swapfile
    exit 1
fi

# * Final Verification
print_info "Info: Verifying swap is active..."
if sudo swapon --show | grep -q "/swapfile"; then
    print_success "Completed: Swap configuration successful. /swapfile is active."
    echo "Current swap status:"
    sudo swapon --show
    echo "Memory status:"
    free -h
else
    print_error "Failed: Swap /swapfile does not appear to be active after configuration."
    exit 1
fi

exit 0 