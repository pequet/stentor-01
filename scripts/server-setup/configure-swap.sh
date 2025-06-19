#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Author: Benjamin Pequet
# Purpose: Configures a 2GB swap file on the system if one is not already active. Intended to be run with sudo.
# Project: https://github.com/pequet/stentor-01/
# Refer to main project for detailed docs.

# * Source Utilities
source "$(dirname "$0")/../utils/messaging_utils.sh"

display_status_message " " "Starting: Swap Configuration"

# * Swap File Check & Activation
# Check if swap is already configured to avoid errors if run multiple times
# A more robust check would be to parse `swapon --show` or `free -h`
if grep -q "/swapfile" /etc/fstab; then
    display_status_message "i" "Info: /swapfile entry already exists in /etc/fstab. Verifying if active..."
    if swapon --show | grep -q "/swapfile"; then
        display_status_message "x" "Completed: Swap /swapfile is already active. No changes made."
        exit 0
    else
        display_status_message "i" "Info: /swapfile entry in /etc/fstab but swap is not active. Attempting to activate..."
        sudo swapon /swapfile
        if swapon --show | grep -q "/swapfile"; then
            display_status_message "x" "Completed: Swap /swapfile activated successfully from existing fstab entry."
            exit 0
        else
            display_status_message "!" "Failed: Could not activate /swapfile despite fstab entry. Please check manually."
            exit 1
        fi
    fi
fi

# * Swap File Creation
display_status_message "i" "Info: Creating a 2GB swap file at /swapfile..."
sudo fallocate -l 2G /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to create swap file with fallocate." >&2 # Keep detailed error for sudo context
    display_status_message "!" "Failed: Swap file creation (fallocate)"
    exit 1
fi

# * Swap File Permissions
display_status_message "i" "Info: Securing the swap file (permissions to 600)..."
sudo chmod 600 /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to set permissions on swap file." >&2
    display_status_message "!" "Failed: Swap file permissions (chmod)"
    # Attempt to clean up before exiting
    sudo rm -f /swapfile
    exit 1
fi

# * Swap Area Setup
display_status_message "i" "Info: Setting up swap area on /swapfile..."
sudo mkswap /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to set up swap area with mkswap." >&2
    display_status_message "!" "Failed: Swap area setup (mkswap)"
    # Attempt to clean up before exiting
    sudo rm -f /swapfile
    exit 1
fi

# * Swap Activation
display_status_message "i" "Info: Enabling the swap on /swapfile..."
sudo swapon /swapfile
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable swap with swapon." >&2
    display_status_message "!" "Failed: Swap activation (swapon)"
    # Attempt to clean up before exiting (though mkswap was successful)
    # Reverting mkswap isn't straightforward, but we can remove the file and fstab entry if added
    sudo rm -f /swapfile 
    exit 1
fi

# * Swap Persistence (fstab)
display_status_message "i" "Info: Making swap permanent by adding to /etc/fstab..."
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
if [ $? -ne 0 ]; then
    echo "Error: Failed to add swap entry to /etc/fstab." >&2
    display_status_message "!" "Failed: Adding swap to /etc/fstab"
    # Attempt to disable swap and remove file as fstab entry failed
    sudo swapoff /swapfile
    sudo rm -f /swapfile
    exit 1
fi

# * Final Verification
display_status_message "i" "Info: Verifying swap is active..."
if sudo swapon --show | grep -q "/swapfile"; then
    display_status_message "x" "Completed: Swap configuration successful. /swapfile is active."
    echo "Current swap status:"
    sudo swapon --show
    echo "Memory status:"
    free -h
else
    display_status_message "!" "Failed: Swap /swapfile does not appear to be active after configuration."
    exit 1
fi

exit 0 