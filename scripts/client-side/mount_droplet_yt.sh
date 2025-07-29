#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Author: Benjamin Pequet
# Purpose: Mounts the Stentor droplet's audio inbox directory to a local mount point using sshfs.
# Project: https://github.com/pequet/stentor-01/ 
# Refer to main project for detailed docs and dependencies (sshfs, macFUSE for macOS).

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
LOG_FILE_PATH="$HOME/.stentor/logs/mount_droplet_yt.log"

# * Configuration Loading
# Determine the directory where this script is located
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf"
HOME_STENTOR_DIR="$HOME/.stentor"
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf"

# ** Dependency Check: sshfs
echo "Checking for sshfs dependency..."
if ! command -v sshfs &> /dev/null; then
    echo "Error: sshfs command not found. This script requires sshfs to mount remote directories." >&2
    os_type=$(uname -s)
    if [ "$os_type" == "Darwin" ]; then # macOS
        echo "It appears you are on macOS." >&2
        echo "To use sshfs on macOS, you need BOTH macFUSE AND SSHFS installed in the correct order:" >&2
        echo "" >&2
        echo "1. First install macFUSE from https://macfuse.github.io/" >&2
        echo "2. After installing macFUSE, you\'ll need to:" >&2
        echo "   - Allow the kernel extension in System Settings > Privacy & Security" >&2
        echo "   - Reboot your computer" >&2
        echo "3. After reboot, install SSHFS from the same website (https://macfuse.github.io/)" >&2
        echo "" >&2
        echo "NOTE: Installing these in the wrong order or not rebooting can cause library errors." >&2
        echo "If you see errors about \'libfuse\' after installation, try uninstalling both" >&2
        echo "and reinstalling in the correct order with a reboot in between." >&2
    elif [ "$os_type" == "Linux" ]; then
        echo "It appears you are on Linux." >&2
        echo "You can likely install sshfs using your package manager. Common commands include:" >&2
        echo "  sudo apt update && sudo apt install sshfs  (for Debian/Ubuntu-based systems)" >&2
        echo "  sudo yum install fuse-sshfs               (for RHEL/CentOS-based systems)" >&2
        echo "  sudo dnf install fuse-sshfs               (for modern Fedora systems)" >&2
        echo "Please consult your distribution\'s documentation if these do not work." >&2
    else
        echo "Unsupported OS for automatic installation guidance: $os_type" >&2
        echo "Please install sshfs using your operating system\'s standard method." >&2
    fi
    echo "After installing sshfs, please run this script again." >&2
    exit 1
fi
# ** End Dependency Check

CONFIG_SOURCED=false
# Try to source project-local stentor.conf file first
if [ -f "$PROJECT_ENV_FILE" ]; then
    # shellcheck source=./stentor.conf
    source "$PROJECT_ENV_FILE"
    CONFIG_SOURCED=true
    print_info "Loaded configuration from $PROJECT_ENV_FILE"
# Else, try to source from $HOME/.stentor/stentor.conf
elif [ -f "$HOME_ENV_FILE" ]; then
    # shellcheck source=~/.stentor/stentor.conf
    source "$HOME_ENV_FILE"
    CONFIG_SOURCED=true
    print_info "Loaded configuration from $HOME_ENV_FILE"
else
    print_error "Configuration file not found." >&2
    print_error "Please create either $PROJECT_ENV_FILE" >&2
    print_error "OR $HOME_ENV_FILE (you might need to create $HOME_STENTOR_DIR first)." >&2
    print_error "You can copy scripts/client-side/stentor_clientstentor.conf.example to one of these locations and populate it." >&2
    exit 1
fi

# Check for necessary variables from the stentor.conf file
REQUIRED_VARS=("STENTOR_REMOTE_USER" "STENTOR_REMOTE_HOST" "STENTOR_REMOTE_AUDIO_INBOX_DIR" "LOCAL_MOUNT_POINT")
missing_vars=0
for var_name in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var_name:-}" ]; then # Check if var is unset or empty
        print_error "Error: Required variable '$var_name' is not set in the sourced stentor.conf file." >&2
        missing_vars=1
    fi
done

if [ "$missing_vars" -eq 1 ]; then
    print_error "Please ensure all required variables are set in your stentor.conf file." >&2
    exit 1
fi

# Ensure local mount point directory exists
if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
    print_info "Local mount point '$LOCAL_MOUNT_POINT' does not exist." >&2
    print_info "Attempting to create it..." >&2
    # Expand tilde if present in LOCAL_MOUNT_POINT
    eval EXPANDED_LOCAL_MOUNT_POINT="$LOCAL_MOUNT_POINT"
    mkdir -p "$EXPANDED_LOCAL_MOUNT_POINT"
    if [ $? -ne 0 ]; then
        print_error "Failed to create local mount point '$EXPANDED_LOCAL_MOUNT_POINT'. Please create it manually." >&2
        exit 1
    fi
    
    # Add a README to the newly created mount point directory for clarity
    INFO_FILE_PATH="$EXPANDED_LOCAL_MOUNT_POINT/README.md"
    print_info "Adding README file to newly created mount point directory: $INFO_FILE_PATH" >&2
    cat > "$INFO_FILE_PATH" << 'EOF_INFO_MOUNT'
# Stentor Droplet Local Mount Point Information

This directory was automatically created by the `mount_droplet_yt.sh` script because it was specified as the LOCAL_MOUNT_POINT in your stentor.conf file and did not already exist.

Its primary purpose is to serve as a local mount point for your Stentor droplet's remote audio inbox (or other configured remote directory via STENTOR_REMOTE_AUDIO_INBOX_DIR).

When this script successfully mounts the remote SSHFS volume here, you will see the contents of the remote directory appear here.

This README is placed here by `mount_droplet_yt.sh` to provide context if you find this directory empty or unmounted.
EOF_INFO_MOUNT
    if [ $? -ne 0 ]; then
        print_warning "Failed to create README file '$INFO_FILE_PATH' in the new mount point directory. Continuing without it." >&2
    fi
    
    print_info "Successfully created local mount point '$EXPANDED_LOCAL_MOUNT_POINT'." >&2
fi

# * Mount Logic
# Check if already mounted
# Expand tilde for grep query as well, if necessary for consistency, though mount output is usually absolute.
eval EXPANDED_LOCAL_MOUNT_POINT_FOR_GREP="$LOCAL_MOUNT_POINT"
if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_FOR_GREP"; then
    print_info "Already mounted at $EXPANDED_LOCAL_MOUNT_POINT_FOR_GREP. Nothing to do."
    exit 0
fi

# SSHFS mount options (can be customized)
# Determine volume name: use STENTOR_VOLUME_NAME from stentor.conf if set, otherwise default
if [ -n "${STENTOR_VOLUME_NAME:-}" ]; then
    VOL_NAME="${STENTOR_VOLUME_NAME}"
else
    VOL_NAME="Stentor Inbox"
fi
print_info "Using volume name: '$VOL_NAME'" >&2

SSHFS_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,default_permissions,volname=${VOL_NAME}"

# Handle optional STENTOR_SSH_KEY_PATH
if [ -n "${STENTOR_SSH_KEY_PATH:-}" ] && [ -f "${STENTOR_SSH_KEY_PATH}" ]; then # Check if var set and file exists
    print_info "Using SSH key: $STENTOR_SSH_KEY_PATH"
    SSHFS_OPTS="IdentityFile=${STENTOR_SSH_KEY_PATH},$SSHFS_OPTS"
fi

# Mounting command
CMD_REMOTE_PATH="$STENTOR_REMOTE_AUDIO_INBOX_DIR"

# If the remote path starts with "~/", remove the "~/" prefix.
# sshfs interprets a path like "stentor_inbox" (without a leading /)
# as relative to the remote user's home directory.
# If the path is just "~", change it to "." to represent the home directory.
if [[ "$CMD_REMOTE_PATH" == "~/"* ]]; then
    print_info "Remote path starts with '~/', using path relative to home: ${CMD_REMOTE_PATH#\~/}" >&2
    CMD_REMOTE_PATH="${CMD_REMOTE_PATH#\~/}"
elif [[ "$CMD_REMOTE_PATH" == "~" ]]; then
    # echo "Info: Remote path is '~', mounting remote home directory itself." >&2
    CMD_REMOTE_PATH="."
fi
# Absolute paths (e.g., /var/www/html) or other relative paths (e.g., my_docs/project1) are used as is.

eval EXPANDED_LOCAL_MOUNT_POINT_CMD="$LOCAL_MOUNT_POINT" # This is for the LOCAL mount point

# echo "Attempting to mount remote path: '${CMD_REMOTE_PATH}' (from original: '${STENTOR_REMOTE_AUDIO_INBOX_DIR}')" >&2
print_step "Attempting to mount: ${STENTOR_REMOTE_USER}@${STENTOR_REMOTE_HOST}:${CMD_REMOTE_PATH} to ${EXPANDED_LOCAL_MOUNT_POINT_CMD}" # Added start message
sshfs "${STENTOR_REMOTE_USER}@${STENTOR_REMOTE_HOST}:${CMD_REMOTE_PATH}" "${EXPANDED_LOCAL_MOUNT_POINT_CMD}" -o "$SSHFS_OPTS"

if [ $? -eq 0 ]; then
    print_success "Successfully mounted: ${STENTOR_REMOTE_USER}@${STENTOR_REMOTE_HOST}:${CMD_REMOTE_PATH} to ${EXPANDED_LOCAL_MOUNT_POINT_CMD}"
else
    print_error "Error: sshfs mount failed for ${EXPANDED_LOCAL_MOUNT_POINT_CMD}"
    echo "Troubleshooting tips:" >&2
    echo "  1. For macOS: Ensure both macFUSE and SSHFS are installed from https://macfuse.github.io/" >&2
    echo "     Install macFUSE first, reboot, then install SSHFS." >&2
    echo "  2. For Linux: Install sshfs (e.g., \'sudo apt install sshfs\')." >&2
    echo "  3. Verify SSH access to ${STENTOR_REMOTE_USER}@${STENTOR_REMOTE_HOST} is working (e.g., \'ssh ${STENTOR_REMOTE_USER}@${STENTOR_REMOTE_HOST}\')." >&2
    echo "  4. Check that the remote directory '${CMD_REMOTE_PATH}' exists on the server." >&2
    echo "  5. Review the variables in your stentor.conf file (either $PROJECT_ENV_FILE or $HOME_ENV_FILE)." >&2
    echo "  6. If using 'allow_other', ensure 'user_allow_other' is set in /etc/fuse.conf (and you may need to be root or use sudo for that option)." >&2
    echo "  7. If using a custom SSH key (STENTOR_SSH_KEY_PATH), ensure it's correct and accessible." >&2
    exit 1
fi

exit 0 