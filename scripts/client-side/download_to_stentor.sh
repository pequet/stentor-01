#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Download YouTube Videos to Stentor
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Downloads YouTube videos and playlists as MP3 files, along with metadata.
#   Manages remote directory mounting/unmounting if configured.
#   Prevents re-downloads using yt-dlp's archive feature.
#
# Features:
#   - Supports multiple YouTube video or playlist URLs.
#   - Allows specifying a custom download destination directory.
#   - If destination is the configured droplet mount point (from stentor.conf):
#     - Automatically mounts the remote directory if not already mounted.
#     - Automatically unmounts after completion ONLY if mounted by this script.
#   - Uses yt-dlp's download archive feature to prevent re-downloading files.
#     The archive file (download_archive.txt) is stored in the destination directory's inbox.
#   - Ensures only one instance of the script runs at a time using a lock file.
#   - Outputs MP3 files with sanitized names: "[Video Title] [Video ID].mp3" to an 'inbox' subdirectory.
#   - Downloads metadata (info.json, description, subtitles) alongside audio.
#
# Usage:
#   ./download_to_stentor.sh [options] <youtube_url1> [youtube_url2 ...]
#
# Options:
#   -d, --destination DIR  Specify the download destination directory.
#                          If not specified, LOCAL_MOUNT_POINT from a stentor.conf file is used if available.
#                          The stentor.conf file is searched in this order:
#                            1. $PROJECT_ENV_FILE
#                            2. $HOME_ENV_FILE
#                          If no stentor.conf is found or LOCAL_MOUNT_POINT is not set, and -d is not used,
#                          the script will exit.
#   -B, --use-break-on-existing Optional. If set, yt-dlp will stop downloading a playlist as soon
#                             as it encounters an item already in the download archive.
#                             Useful for frequent runs on long, mostly static playlists.
#   -h, --help             Display this help message and exit.
#
# Dependencies:
#   - yt-dlp: The core YouTube download utility.
#   - mount_droplet_yt.sh: (In script directory) Required for automatic mounting.
#   - unmount_droplet_yt.sh: (In script directory) Required for automatic unmounting.
#   - sshfs: Required by the mount/unmount scripts.
#   - Standard Unix utilities: date, cat, stat, kill, rm, mkdir, mount, sleep.
#
# Changelog:
#   1.0.0 - 2025-05-25 - Initial release with download, mount management, and metadata capabilities.
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

# * Source Utilities
source "$(dirname "$0")/../utils/messaging_utils.sh"

# * Global Variables and Configuration

# ** Script & Environment Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf"
HOME_STENTOR_DIR="$HOME/.stentor"
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf"

# Lock configuration
LOCK_FILE="$HOME/.stentor/download_to_stentor.lock"
LOCK_TIMEOUT=300  # 300 seconds timeout for download operations
LOCK_ACQUIRED_BY_THIS_PROCESS=false # Flag to track if this instance acquired the lock

# Ensure HOME_STENTOR_DIR exists for lock files etc.
if [ ! -d "$HOME_STENTOR_DIR" ]; then
    mkdir -p "$HOME_STENTOR_DIR"
    if [ $? -ne 0 ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DOWNLOAD_TO_STENTOR] Error: Could not create $HOME_STENTOR_DIR. Lock file and other operations might fail." >&2
        # Decide if this is a fatal error or if we can proceed with lock file in /tmp
        # For now, let's assume it's not immediately fatal but warn heavily.
    fi
fi

DOWNLOAD_URLS=()
DESTINATION_OVERRIDE=""
FINAL_DESTINATION_DIR=""
LOCAL_MOUNT_POINT="" # Will be loaded from stentor.conf
SCRIPT_PERFORMED_MOUNT=false
YT_DLP_USE_BREAK_ON_EXISTING=false # New flag variable

MOUNT_SCRIPT="$SCRIPT_DIR/mount_droplet_yt.sh"
UNMOUNT_SCRIPT="$SCRIPT_DIR/unmount_droplet_yt.sh"

# * Logging Function
echo_log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DOWNLOAD_TO_STENTOR] INFO: $1"
}
echo_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DOWNLOAD_TO_STENTOR] ERROR: $1" >&2
}
echo_warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DOWNLOAD_TO_STENTOR] WARNING: $1" >&2
}

# * Helper Function: Verify Mount Point
_is_mount_verified_and_responsive() {
    local mount_path_to_check="$1"
    echo_log "Verifying mount: Step 1 - Checking OS mount table for '$mount_path_to_check'..."
    if ! mount | grep -q " on $mount_path_to_check "; then
        echo_log "Verification Step 1 FAILED: '$mount_path_to_check' not found in 'mount' output (or pattern ' on $mount_path_to_check ' did not match)."
        return 1 # Failure
    fi
    echo_log "Verification Step 1 PASSED: '$mount_path_to_check' found in OS mount table."

    echo_log "Verifying mount: Step 2 - Checking responsiveness of '$mount_path_to_check'..."
    if ! ls -A -1 "$mount_path_to_check" >/dev/null 2>&1; then
        echo_error "Verification Step 2 FAILED: Mount point '$mount_path_to_check' is not responsive or accessible (ls command failed)."
        return 1 # Failure
    fi
    echo_log "Verification Step 2 PASSED: Mount point '$mount_path_to_check' is responsive."
    return 0 # Success
}

# * Lock Management
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        local lock_file_age_info="(age not calculated)"
        local lock_file_age_seconds=-1

        echo "--- DEBUG LOCK START ---" >&2
        echo "DEBUG: Lock file found: $LOCK_FILE" >&2
        echo "DEBUG: Content of LOCK_FILE (PID read): '$lock_pid'" >&2

        local current_time=$(date +%s)
        local file_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)

        if [[ -n "$file_mod_time" ]]; then
            lock_file_age_seconds=$((current_time - file_mod_time))
            lock_file_age_info="(Age: ${lock_file_age_seconds}s, Timeout: ${LOCK_TIMEOUT}s)"
            echo "DEBUG: Calculated lock_file_age_seconds: $lock_file_age_seconds" >&2
            echo "DEBUG: LOCK_TIMEOUT: $LOCK_TIMEOUT" >&2
            echo "DEBUG: Formatted lock_file_age_info: $lock_file_age_info" >&2
        else
            lock_file_age_info="(could not determine age)"
            echo "DEBUG: Could not determine file_mod_time. lock_file_age_seconds remains $lock_file_age_seconds." >&2
        fi

        local pid_check_command_exit_code
        if [[ -n "$lock_pid" ]]; then
            echo "DEBUG: Preparing to check PID $lock_pid with 'kill -0 $lock_pid'" >&2
            kill -0 "$lock_pid" 2>/dev/null
            pid_check_command_exit_code=$?
            echo "DEBUG: 'kill -0 $lock_pid' exit code: $pid_check_command_exit_code" >&2
        else
            echo "DEBUG: lock_pid is empty. Assuming PID not running." >&2
            pid_check_command_exit_code=1 # Simulate PID not running if lock_pid is empty
        fi

        if [[ "$pid_check_command_exit_code" -eq 0 ]]; then
            echo "DEBUG:BRANCH TAKEN: PID $lock_pid IS considered RUNNING." >&2
            echo_error "Another download instance is running (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
            echo "--- DEBUG LOCK END (PID RUNNING) ---" >&2
            exit 2
        else
            echo "DEBUG BRANCH TAKEN: PID $lock_pid IS considered NOT RUNNING (or PID was empty)." >&2
            if [[ "$lock_file_age_seconds" -ne -1 ]]; then # Age was successfully calculated
                echo "DEBUG: Comparing age: $lock_file_age_seconds > $LOCK_TIMEOUT ?" >&2
                if [[ "$lock_file_age_seconds" -gt "$LOCK_TIMEOUT" ]]; then
                    echo "DEBUG: AGE COMPARISON TRUE. Lock IS STALE." >&2
                    echo_log "Removing stale lock file (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
                    rm -f "$LOCK_FILE"
                else
                    echo "DEBUG: AGE COMPARISON FALSE. Lock IS NOT STALE ENOUGH." >&2
                    echo_error "Lock file (PID: $lock_pid) exists but is not older than timeout. Details: $lock_file_age_info. Not removing. Lock file: $LOCK_FILE"
                    echo "--- DEBUG LOCK END (PID NOT RUNNING, NOT STALE ENOUGH) ---" >&2
                    exit 2
                fi
            else # Age could not be determined earlier
                echo "DEBUG: Age could not be calculated. Assuming stale and removing." >&2
                echo_warn "Could not determine age of lock file (PID: $lock_pid). Details: $lock_file_age_info. Assuming stale and removing. Lock file: $LOCK_FILE"
                rm -f "$LOCK_FILE"
            fi
        fi
    fi
    
    echo "DEBUG: Proceeding to create new lock file." >&2
    mkdir -p "$(dirname "$LOCK_FILE")"
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED_BY_THIS_PROCESS=true # Set flag as lock is acquired by this process
    echo "--- DEBUG LOCK END (NEW LOCK CREATED or NO LOCK INITIALLY) ---" >&2
    return 0
}

release_lock() {
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        echo "DEBUG: release_lock called by owning process (PID: $$). Removing $LOCK_FILE" >&2
        rm -f "$LOCK_FILE"
    else
        echo "DEBUG: release_lock called, but lock not owned by this process (PID: $$). Lock file $LOCK_FILE not removed by this instance." >&2
    fi
}

# * Cleanup Function
cleanup() {
    local last_exit_status="$?" 
    display_status_message "i" "Info: Executing cleanup routine (Exit status: $last_exit_status)"
    release_lock

    # Best-effort save for an interrupted CURRENT_URL_TEMP_DIR
    if [ -n "${CURRENT_URL_TEMP_DIR:-}" ] && [ -d "$CURRENT_URL_TEMP_DIR" ]; then
        if [ "$(ls -A "$CURRENT_URL_TEMP_DIR" 2>/dev/null)" ]; then # If directory has files
            echo_log "Cleanup: CURRENT_URL_TEMP_DIR ($CURRENT_URL_TEMP_DIR) contains files."
            if [ -n "${REMOTE_INBOX_DIR:-}" ]; then
                # We should ideally check if REMOTE_INBOX_DIR is accessible (mount is up)
                # For now, assume if it's set, we attempt. A more robust check could be added later if needed.
                echo_log "Cleanup: Attempting to transfer contents of '$CURRENT_URL_TEMP_DIR' to '$REMOTE_INBOX_DIR' (best effort on exit)..."
                # Use --ignore-existing. Do NOT use --remove-source-files here. This is a copy. Exclude .part and .ytdl files.
                rsync -av --ignore-existing --exclude='*.part' --exclude='*.ytdl' "${CURRENT_URL_TEMP_DIR}/" "${REMOTE_INBOX_DIR}/"
                rsync_cleanup_exit_code=$?
                if [ $rsync_cleanup_exit_code -eq 0 ]; then
                    echo_log "Cleanup: Successfully transferred contents from '$CURRENT_URL_TEMP_DIR' to '$REMOTE_INBOX_DIR'."
                else
                    echo_error "Cleanup: rsync from '$CURRENT_URL_TEMP_DIR' to '$REMOTE_INBOX_DIR' failed during cleanup (code $rsync_cleanup_exit_code)."
                    echo_warn "Cleanup: Files from '$CURRENT_URL_TEMP_DIR' might not have been fully transferred to remote."
                fi
            else
                echo_warn "Cleanup: REMOTE_INBOX_DIR not set. Cannot transfer files from '$CURRENT_URL_TEMP_DIR' on exit."
                echo_warn "Cleanup: Files for the last processed URL may remain in '$CURRENT_URL_TEMP_DIR' until it is removed."
            fi
        else
             echo_log "Cleanup: CURRENT_URL_TEMP_DIR ($CURRENT_URL_TEMP_DIR) is empty."
        fi
        
        # Always remove the specific URL's temp dir during cleanup if it exists
        echo_log "Cleanup: Removing CURRENT_URL_TEMP_DIR: $CURRENT_URL_TEMP_DIR"
        rm -rf "$CURRENT_URL_TEMP_DIR"
        if [ $? -eq 0 ]; then
            echo_log "Cleanup: Successfully removed temporary directory $CURRENT_URL_TEMP_DIR"
        else
            echo_error "Cleanup: Failed to remove temporary directory $CURRENT_URL_TEMP_DIR. Manual check may be needed."
        fi
    else
        echo_log "Cleanup: CURRENT_URL_TEMP_DIR ('${CURRENT_URL_TEMP_DIR:-}') not set or not a directory during cleanup. No specific URL temp dir operations."
    fi

    if [ "$SCRIPT_PERFORMED_MOUNT" = true ]; then
        echo_log "Script performed mount, attempting to unmount..."
        if [ -x "$UNMOUNT_SCRIPT" ]; then
            if [ -n "$LOCAL_MOUNT_POINT" ]; then # Ensure LOCAL_MOUNT_POINT is known
                eval EXPANDED_LOCAL_MOUNT_POINT_CLEANUP="$LOCAL_MOUNT_POINT"
                if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"; then
                    echo_log "Calling unmount script: $UNMOUNT_SCRIPT for $EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"
                    echo_log "Waiting 2 seconds before unmount to allow file operations to settle..."
                    sleep 2
                    "$UNMOUNT_SCRIPT"
                    if [ $? -eq 0 ]; then
                        echo_log "Successfully unmounted '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script."
                    else
                        echo_error "Failed to unmount '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script. Manual unmount may be required."
                    fi
                else
                    echo_log "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' is not currently mounted. No unmount needed by script."
                fi
            else
                 echo_warn "LOCAL_MOUNT_POINT is not set. Cannot attempt conditional unmount."
            fi
        else
            echo_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot unmount automatically."
        fi
    else
        echo_log "Script did not perform mount, or mount point not specified for unmount. No unmount action taken by script."
    fi

    # # Aggressively cleanup the base local temporary directory if it was defined and exists
    # if [ -n "${LOCAL_TEMP_BASE_DIR:-}" ] && [ -d "$LOCAL_TEMP_BASE_DIR" ]; then
    #     echo_log "Aggressively cleaning up base local temporary directory: $LOCAL_TEMP_BASE_DIR"
    #     rm -rf "$LOCAL_TEMP_BASE_DIR"
    #     if [ $? -eq 0 ]; then
    #         echo_log "Successfully removed base local temporary directory: $LOCAL_TEMP_BASE_DIR"
    #     else
    #         # This error primarily matters for manual inspection if the script was failing to create it initially.
    #         # If the script ran, individual CURRENT_URL_TEMP_DIRs should be handled by the loop.
    #         echo_error "Failed to remove base local temporary directory: $LOCAL_TEMP_BASE_DIR. It might have already been removed or there was an issue."
    #     fi
    # else
    #     echo_log "Base local temporary directory '$LOCAL_TEMP_BASE_DIR' was not defined or does not exist. No cleanup needed for it."
    # fi

    echo_log "Cleanup routine finished."
}

# Set trap for cleanup on EXIT or signals
trap cleanup EXIT INT TERM HUP

# * Usage Function
usage() {
    cat << EOF
Usage: $0 [options] <youtube_url1> [youtube_url2 ...]

Downloads YouTube videos and playlists as MP3 files.

Features:
  - Supports multiple YouTube video or playlist URLs.
  - Allows specifying a custom download destination directory.
  - If destination is the configured droplet mount point (from stentor.conf):
    - Automatically mounts the remote directory if not already mounted.
    - Automatically unmounts after completion ONLY if mounted by this script.
  - Uses yt-dlp's download archive feature to prevent re-downloading files.
    The archive file (download_archive.txt) is stored in the destination directory.
  - Ensures only one instance of the script runs at a time using a lock file.
  - Outputs MP3 files with sanitized names: "[Video Title] [Video ID].mp3".

Options:
  -d, --destination DIR  Specify the download destination directory.
                         If not specified, LOCAL_MOUNT_POINT from a stentor.conf file is used if available.
                         The stentor.conf file is searched in this order:
                           1. $PROJECT_ENV_FILE
                           2. $HOME_ENV_FILE
                         If no stentor.conf is found or LOCAL_MOUNT_POINT is not set, and -d is not used,
                         the script will exit.
  -B, --use-break-on-existing Optional. If set, yt-dlp will stop downloading a playlist as soon
                             as it encounters an item already in the download archive.
                             Useful for frequent runs on long, mostly static playlists.
  -h, --help             Display this help message and exit.

Dependencies:
  - yt-dlp:               The core YouTube download utility.
  - mount_droplet_yt.sh:  (In script directory) Required for automatic mounting.
  - unmount_droplet_yt.sh:(In script directory) Required for automatic unmounting.
  - sshfs:                Required by the mount/unmount scripts.

Lock File:
  A lock file is used to ensure only one instance of this script runs at a time.
  Location: $LOCK_FILE

Example:
  $0 https://www.youtube.com/watch?v=dQw4w9WgXcQ
  $0 -d /my/local/music/ https://www.youtube.com/playlist?list=PL.....

Exit Codes:
  0: Success
  1: Missing dependencies or config
  2: Directory listing/parsing error
  3: Failed to create directories
  4: Mount failure
  5: SSHFS connection loss during download
EOF
    exit 1
}

# * Argument Parsing
parse_arguments() {
    DOWNLOAD_URLS=() # Reset for safety if called multiple times (though not planned)
    DESTINATION_OVERRIDE=""
    YT_DLP_USE_BREAK_ON_EXISTING=false # Ensure reset if function were re-called

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -d|--destination)
                if [ -n "$2" ]; then
                    DESTINATION_OVERRIDE="$2"
                    shift 
                else
                    echo_error "--destination option requires a directory path."
                    usage
                fi
                ;;
            -B|--use-break-on-existing)
                YT_DLP_USE_BREAK_ON_EXISTING=true
                ;;
            -h|--help)
                usage
                ;;
            -*)
                echo_error "Unknown option '$1'"
                usage
                ;;
            *)
                DOWNLOAD_URLS+=("$1")
                ;;
        esac
        shift
    done

    if [ ${#DOWNLOAD_URLS[@]} -eq 0 ]; then
        echo_error "No YouTube URLs provided."
        usage
    fi
}

# * Helper: Check for required commands
check_command_exists() {
    local cmd="$1"
    local critical=${2:-true} # Second arg: true if critical, false if optional/checked by other scripts
    if ! command -v "$cmd" &> /dev/null; then
        echo_error "Required command '$cmd' not found in PATH."
        if [ "$critical" = true ]; then
            echo_error "Please install '$cmd' and ensure it is in your PATH."
            exit 1
        fi
        return 1
    fi
    echo_log "Command '$cmd' found."
    return 0
}

# * Main Script Logic
main() {
    parse_arguments "$@"

    display_status_message " " "Starting: YouTube Download to Stentor"

    echo_log "URLs to process:"
    for url in "${DOWNLOAD_URLS[@]}"; do
        echo_log "  - $url"
    done

    # 1. Acquire lock
    echo_log "Acquiring lock..."
    acquire_lock
    echo_log "Lock acquired successfully."

    # 2. Dependency checks
    echo_log "Performing dependency checks..."
    check_command_exists "yt-dlp" true
    # sshfs is checked by mount_droplet_yt.sh, but checking here is good for clarity
    check_command_exists "sshfs" false # Not strictly critical for this script if not mounting

    if [ ! -x "$MOUNT_SCRIPT" ]; then
        echo_error "Mount script not found or not executable: $MOUNT_SCRIPT"
        display_status_message "!" "Failed: Mount script $MOUNT_SCRIPT not found/executable"
        exit 1
    fi
    echo_log "Mount script '$MOUNT_SCRIPT' found."
    if [ ! -x "$UNMOUNT_SCRIPT" ]; then
        echo_error "Unmount script not found or not executable: $UNMOUNT_SCRIPT"
        display_status_message "!" "Failed: Unmount script $UNMOUNT_SCRIPT not found/executable"
        exit 1
    fi
    echo_log "Unmount script '$UNMOUNT_SCRIPT' found."
    echo_log "Dependency checks passed."

    # 3. Load stentor.conf configuration
    echo_log "Attempting to load stentor.conf configuration..."
    CONFIG_SOURCED=false
    if [ -f "$PROJECT_ENV_FILE" ]; then
        echo_log "Found project stentor.conf file: $PROJECT_ENV_FILE. Sourcing..."
        # shellcheck source=./stentor.conf
        source "$PROJECT_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}" # Ensure it's defined, even if empty after source
        echo_log "Loaded configuration from $PROJECT_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    elif [ -f "$HOME_ENV_FILE" ]; then
        echo_log "Found home stentor.conf file: $HOME_ENV_FILE. Sourcing..."
        # shellcheck source=~/.stentor/stentor.conf
        source "$HOME_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}"
        echo_log "Loaded configuration from $HOME_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    else
        echo_log "No stentor.conf file found at $PROJECT_ENV_FILE or $HOME_ENV_FILE."
    fi
    if [ ! "$CONFIG_SOURCED" = true ]; then
        echo_warn "No stentor.conf file was sourced. LOCAL_MOUNT_POINT will be empty unless destination is overridden."
    fi

    # 4. Determine Final Destination Directory
    echo_log "Determining final destination directory..."
    if [ -n "$DESTINATION_OVERRIDE" ]; then
        eval FINAL_DESTINATION_DIR="$DESTINATION_OVERRIDE" # Expand tilde if user provided one
        echo_log "Using destination override: $FINAL_DESTINATION_DIR"
    elif [ -n "$LOCAL_MOUNT_POINT" ]; then
        eval FINAL_DESTINATION_DIR="$LOCAL_MOUNT_POINT"
        echo_log "Using LOCAL_MOUNT_POINT from stentor.conf as destination: $FINAL_DESTINATION_DIR"
    else
        # This path should ideally not be reached if logic above is correct, but as a safeguard:
        echo_error "Critical Error: Destination could not be determined. LOCAL_MOUNT_POINT is empty and no override was provided."
        display_status_message "!" "Failed: Could not determine download destination"
        usage # or exit 1 directly
    fi
    echo_log "Final destination directory set to: '$FINAL_DESTINATION_DIR'"

    # 5. Mount Management (if destination is the configured LOCAL_MOUNT_POINT)
    SCRIPT_PERFORMED_MOUNT=false # Reset before attempting mount
    if [ -n "$LOCAL_MOUNT_POINT" ]; then # Only if LOCAL_MOUNT_POINT was defined in stentor.conf
        eval EXPANDED_LOCAL_MOUNT_POINT_CHECK="$LOCAL_MOUNT_POINT"
        eval EXPANDED_FINAL_DESTINATION_DIR_CHECK="$FINAL_DESTINATION_DIR"

        # Check if the final destination IS the local mount point
        if [ "$EXPANDED_FINAL_DESTINATION_DIR_CHECK" == "$EXPANDED_LOCAL_MOUNT_POINT_CHECK" ]; then
            echo_log "Destination '$FINAL_DESTINATION_DIR' is the configured remote mount point. Verifying..."
            
            if _is_mount_verified_and_responsive "$EXPANDED_FINAL_DESTINATION_DIR_CHECK"; then
                echo_log "Mount '$EXPANDED_FINAL_DESTINATION_DIR_CHECK' is already active and responsive."
            else
                echo_log "Mount '$EXPANDED_FINAL_DESTINATION_DIR_CHECK' not verified or not responsive. Attempting to remediate..."
                # Attempt to unmount first, in case of a stale mount
                # Check if it's even in the mount table before trying to unmount
                if mount | grep -q " on $EXPANDED_FINAL_DESTINATION_DIR_CHECK "; then
                    echo_log "Attempting to unmount potentially stale mount at '$EXPANDED_FINAL_DESTINATION_DIR_CHECK'..."
                    if [ -x "$UNMOUNT_SCRIPT" ]; then
                        "$UNMOUNT_SCRIPT" # This script should handle its own logging for success/failure
                        sleep 2 # Give unmount a moment
                    else
                        echo_warn "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot attempt unmount."
                    fi
                fi

                echo_log "Attempting to mount '$EXPANDED_FINAL_DESTINATION_DIR_CHECK' via $MOUNT_SCRIPT..."
                if [ -x "$MOUNT_SCRIPT" ]; then
                    "$MOUNT_SCRIPT"
                    if [ $? -eq 0 ]; then
                        echo_log "Mount script '$MOUNT_SCRIPT' executed successfully. Verifying mount again..."
                        if _is_mount_verified_and_responsive "$EXPANDED_FINAL_DESTINATION_DIR_CHECK"; then
                            echo_log "Successfully mounted and verified '$EXPANDED_FINAL_DESTINATION_DIR_CHECK'."
                            SCRIPT_PERFORMED_MOUNT=true
                        else
                            echo_error "Mount script executed, but '$EXPANDED_FINAL_DESTINATION_DIR_CHECK' is STILL not verified or responsive."
                            display_status_message "!" "Failed: Mount verification failed for $EXPANDED_FINAL_DESTINATION_DIR_CHECK after mount attempt"
                            exit 4
                        fi
                    else
                        echo_error "Mount script '$MOUNT_SCRIPT' failed to execute properly."
                        display_status_message "!" "Failed: Mount script $MOUNT_SCRIPT execution error"
                        exit 4 # Specific exit code for mount failure
                    fi
                else
                    echo_error "Mount script '$MOUNT_SCRIPT' not found or not executable. Cannot mount automatically."
                    display_status_message "!" "Failed: Mount script $MOUNT_SCRIPT not found/executable"
                    exit 1 # Config/dependency error
                fi
            fi
            # At this point, if we haven't exited, the mount should be verified and responsive.
            # The old "CRITICAL: Final mount verification" block is now covered by the _is_mount_verified_and_responsive calls.
        else
            echo_log "Destination '$FINAL_DESTINATION_DIR' is not the configured remote mount point. No mount action needed for this destination."
        fi
    else
        echo_log "LOCAL_MOUNT_POINT not defined in stentor.conf. Assuming local download, no mount action needed."
    fi

    # 6. Ensure Destination Directory Exists
    echo_log "Checking if destination directory '$FINAL_DESTINATION_DIR' exists..."
    if [ ! -d "$FINAL_DESTINATION_DIR" ]; then
        echo_log "Destination directory does not exist. Attempting to create it..."
        mkdir -p "$FINAL_DESTINATION_DIR"
        if [ $? -ne 0 ]; then
            echo_error "Failed to create destination directory '$FINAL_DESTINATION_DIR'. Please check permissions or create it manually."
            display_status_message "!" "Failed: Could not create destination $FINAL_DESTINATION_DIR"
            exit 3
        fi
        echo_log "Successfully created destination directory '$FINAL_DESTINATION_DIR'."
    else
        echo_log "Destination directory '$FINAL_DESTINATION_DIR' already exists."
    fi

    # Define base local temporary directory
    LOCAL_TEMP_BASE_DIR="$HOME/.stentor/temp_downloads"
    echo_log "Ensuring base local temporary directory exists: $LOCAL_TEMP_BASE_DIR"
    mkdir -p "$LOCAL_TEMP_BASE_DIR"
    if [ $? -ne 0 ]; then
        echo_error "Failed to create base local temporary directory '$LOCAL_TEMP_BASE_DIR'. Please check permissions."
        display_status_message "!" "Failed: Could not create base temp dir $LOCAL_TEMP_BASE_DIR"
        exit 3 # Using same exit code as other directory creation failures for now
    fi
    echo_log "Base local temporary directory ensured: $LOCAL_TEMP_BASE_DIR"

    # 7. yt-dlp Execution Loop
    echo_log "Starting download process with yt-dlp..."
    
    # Target the inbox subdirectory within the destination directory (this is the REMOTE inbox)
    REMOTE_INBOX_DIR="$FINAL_DESTINATION_DIR/inbox"
    echo_log "Target remote inbox directory: $REMOTE_INBOX_DIR"
    
    # Ensure remote inbox directory exists
    if [ ! -d "$REMOTE_INBOX_DIR" ]; then
        echo_log "Remote inbox directory does not exist. Creating: $REMOTE_INBOX_DIR"
        mkdir -p "$REMOTE_INBOX_DIR"
        if [ $? -ne 0 ]; then
            echo_error "Failed to create remote inbox directory '$REMOTE_INBOX_DIR'. Please check permissions."
            display_status_message "!" "Failed: Could not create remote inbox $REMOTE_INBOX_DIR"
            exit 3
        fi
        echo_log "Successfully created remote inbox directory '$REMOTE_INBOX_DIR'."
    else
        echo_log "Remote inbox directory '$REMOTE_INBOX_DIR' already exists."
    fi
    
    REMOTE_DOWNLOAD_ARCHIVE_FILE="$REMOTE_INBOX_DIR/download_archive.txt"
    echo_log "Remote download archive will be at: $REMOTE_DOWNLOAD_ARCHIVE_FILE"

    PROCESSED_COUNT=0
    FAIL_COUNT=0

    for url in "${DOWNLOAD_URLS[@]}"; do
        echo_log "Processing URL: $url"

        CURRENT_URL_TEMP_DIR="" # Initialize
        CURRENT_URL_TEMP_DIR=$(mktemp -d "${LOCAL_TEMP_BASE_DIR}/stentor_dl_XXXXXX")

        if [ -z "$CURRENT_URL_TEMP_DIR" ] || [ ! -d "$CURRENT_URL_TEMP_DIR" ]; then
            echo_error "Failed to create unique temporary directory for URL: $url in $LOCAL_TEMP_BASE_DIR"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue # Skip to the next URL
        fi
        echo_log "Created temporary download directory for '$url': $CURRENT_URL_TEMP_DIR"
        
        # Output template: LocalTempDir/Video Title [Video ID].mp3
        # Download archive points to the REMOTE location
        yt_dlp_cmd=(
            yt-dlp \
            -x --audio-format mp3 --audio-quality 0 \
            --download-archive "$REMOTE_DOWNLOAD_ARCHIVE_FILE" \
            -o "$CURRENT_URL_TEMP_DIR/%(title)s [%(id)s].%(ext)s" \
            --restrict-filenames \
            --progress \
            -i \
            --no-warnings \
            --write-info-json \
            --write-description \
            --write-subs \
            --write-auto-subs \
            --sub-format "srt/vtt/best" \
            --sub-langs "en.*" \
            --no-write-playlist-metafiles \
            --match-filter '!is_live' \
            --fragment-retries 2 \
            --retries 2 \
            --no-skip-unavailable-fragments \
        )

        if [ "$YT_DLP_USE_BREAK_ON_EXISTING" = true ]; then
            echo_log "Optional flag --use-break-on-existing is active. Adding to yt-dlp command."
            yt_dlp_cmd+=(--break-on-existing)
        fi
        
        yt_dlp_cmd+=("$url")

        echo_log "Executing: ${yt_dlp_cmd[*]}"
        
        # Capture both stdout and stderr for better error analysis
        # Old method that suppressed real-time output:
        # yt_dlp_output=$("${yt_dlp_cmd[@]}" 2>&1)
        # yt_dlp_exit_code=$?

        # New method using tee to show real-time output and capture for analysis
        temp_output_file="" # Initialize
        temp_output_file=$(mktemp) # Create a temporary file, mktemp is safer
        if [ -z "$temp_output_file" ] || [ ! -f "$temp_output_file" ]; then
            # Fallback if mktemp fails for some reason, though unlikely
            echo_error "mktemp failed to create a temporary file. Falling back to direct execution (no output capture for error analysis)."
            "${yt_dlp_cmd[@]}" # Execute directly, progress will show, but no capture
            yt_dlp_exit_code=$?
            yt_dlp_output="mktemp failed, yt-dlp output not captured."
        else
            # POSIX sh compatible way to pipe and capture exit status of piped command
            # This is more complex than bash's PIPESTATUS but more portable if needed.
            # For bash, PIPESTATUS is simpler. Given it's a bash script, we can use PIPESTATUS.
            # Ensure PIPESTATUS is used correctly for bash:
            # Need to run in a subshell or manage the pipe carefully if we want to avoid subshell for variable scope
            # Using process substitution for tee's output to avoid subshell for yt_dlp_output variable
            # However, a simple pipe is more common and PIPESTATUS handles it well in bash

            "${yt_dlp_cmd[@]}" 2>&1 | tee "$temp_output_file"
            yt_dlp_exit_code=${PIPESTATUS[0]} # Get exit code of yt-dlp (left side of pipe)
            
            yt_dlp_output=$(cat "$temp_output_file")
            rm "$temp_output_file"
        fi
        
        if [ $yt_dlp_exit_code -eq 0 ]; then
            echo_log "yt-dlp completed successfully for URL: $url (local download to $CURRENT_URL_TEMP_DIR)"

            # Check if there are any files to transfer (excluding .part and .ytdl)
            # We use find to list files, then grep to filter out those we'd exclude, then wc -l to count.
            # This is more robust than ls if filenames have spaces or special characters.
            files_to_transfer_count=$(find "$CURRENT_URL_TEMP_DIR" -type f ! -name '*.part' ! -name '*.ytdl' -print 2>/dev/null | wc -l)
            
            if [ "$files_to_transfer_count" -gt 0 ]; then
                echo_log "Found $files_to_transfer_count file(s) in '$CURRENT_URL_TEMP_DIR' to transfer to '$REMOTE_INBOX_DIR'..."
                # Exclude .part and .ytdl files from being transferred.
                rsync -av --remove-source-files --exclude='*.part' --exclude='*.ytdl' "${CURRENT_URL_TEMP_DIR}/" "${REMOTE_INBOX_DIR}/"
                rsync_exit_code=$?

                if [ $rsync_exit_code -eq 0 ]; then
                    echo_log "Successfully transferred files from '$CURRENT_URL_TEMP_DIR' to '$REMOTE_INBOX_DIR'."
                    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
                    # Since rsync with --remove-source-files succeeded, local temp files should be gone.
                    # The directory CURRENT_URL_TEMP_DIR itself should be empty now.
                else
                    echo_error "rsync failed to transfer files from '$CURRENT_URL_TEMP_DIR' to '$REMOTE_INBOX_DIR' (exit code: $rsync_exit_code)."
                    echo_error "Downloaded files for '$url' *may* remain in local temporary directory: $CURRENT_URL_TEMP_DIR (if rsync didn't remove any)."
                    echo_error "The download archive '$REMOTE_DOWNLOAD_ARCHIVE_FILE' on the remote *may* have been updated by yt-dlp, but files were not reliably transferred to '$REMOTE_INBOX_DIR'."
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            else
                echo_log "No new files to transfer from '$CURRENT_URL_TEMP_DIR' for URL: $url (directory is empty or only contains excluded file types)."
                # Even if nothing was transferred, yt-dlp considered this URL processed (e.g., already in archive)
                # So we should still count it as processed if yt-dlp itself exited successfully.
                PROCESSED_COUNT=$((PROCESSED_COUNT + 1)) 
            fi
        else
            echo_error "yt-dlp failed for URL: $url with exit code $yt_dlp_exit_code."
            FAIL_COUNT=$((FAIL_COUNT + 1)) # Increment fail count here for yt-dlp failures
            
            # Check for mount-related errors in the output (even on yt-dlp failure)
            if echo "$yt_dlp_output" | grep -qi "device not configured\|socket is not connected\|no such file or directory.*mount"; then
                echo_error "DETECTED MOUNT FAILURE (from yt-dlp output): The error appears to be related to a lost SSHFS connection."
                echo_error "This typically happens when:"
                echo_error "  - Network connection is unstable"
                echo_error "  - SSH session timeout occurs" 
                echo_error "  - Remote server closes the connection"
                echo_error ""
                echo_error "Troubleshooting steps:"
                echo_error "  1. Check network connectivity to the remote server"
                echo_error "  2. Verify SSH key authentication is working"
                echo_error "  3. Consider increasing SSH timeout settings"
                echo_error "  4. Try running the script again (it will attempt to remount)"
                echo_error ""
                echo_error "Raw yt-dlp output for '$url':"
                echo "$yt_dlp_output"
                
                display_status_message "!" "Failed: SSHFS connection lost during download (URL: $url)"
                # Cleanup the local temporary directory for this failed URL before exiting
                if [ -n "$CURRENT_URL_TEMP_DIR" ] && [ -d "$CURRENT_URL_TEMP_DIR" ]; then
                    echo_log "Cleaning up temporary directory '$CURRENT_URL_TEMP_DIR' due to critical mount failure for '$url'..."
                    rm -rf "$CURRENT_URL_TEMP_DIR"
                fi
                exit 5 # Exit immediately on mount failure - no point continuing
            else
                echo_error "Raw yt-dlp output for '$url':"
                echo "$yt_dlp_output"
                # FAIL_COUNT already incremented above for general yt-dlp failure
                echo_log "Continuing with remaining URLs after yt-dlp failure for '$url'..."
            fi
        fi

        # Unconditional cleanup of the current URL's temporary directory
        if [ -n "$CURRENT_URL_TEMP_DIR" ] && [ -d "$CURRENT_URL_TEMP_DIR" ]; then
            echo_log "Cleaning up local temporary directory for '$url': $CURRENT_URL_TEMP_DIR"
            rm -rf "$CURRENT_URL_TEMP_DIR"
            if [ $? -eq 0 ]; then
                echo_log "Successfully removed temporary directory: $CURRENT_URL_TEMP_DIR"
            else
                echo_error "Failed to remove temporary directory: $CURRENT_URL_TEMP_DIR. Manual check may be needed."
            fi
        fi

        # ADDED: Explicit mount re-verification after each URL processing if destination is the mount point
        if [ -n "$LOCAL_MOUNT_POINT" ]; then
            eval EXPANDED_LOCAL_MOUNT_POINT_LOOP_CHECK="$LOCAL_MOUNT_POINT"
            eval EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK="$FINAL_DESTINATION_DIR"

            if [ "$EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK" == "$EXPANDED_LOCAL_MOUNT_POINT_LOOP_CHECK" ]; then
                echo_log "Re-verifying mount point '$EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK' after processing URL: $url"
                if ! _is_mount_verified_and_responsive "$EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK"; then
                    echo_error "CRITICAL MID-PROCESS FAILURE: Mount point '$EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK' became unresponsive or was lost after processing URL: $url."
                    echo_error "This indicates a likely SSHFS connection drop during the download process."
                    echo_error "Script will exit to prevent further errors or writing to incorrect locations."
                    display_status_message "!" "Critical Failure: Mount point $EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK lost mid-process. Halting."
                    # CURRENT_URL_TEMP_DIR for the URL that just finished *should* have already been cleaned up above.
                    # The main trap cleanup will handle LOCAL_TEMP_BASE_DIR.
                    exit 5 # Specific exit code for critical mount failure detected post-URL processing
                else
                    echo_log "Mount point '$EXPANDED_FINAL_DESTINATION_DIR_LOOP_CHECK' remains verified and responsive after processing URL: $url"
                fi
            fi
        fi
    done

    display_status_message "x" "Completed: YouTube Download (Processed URLs/Playlists: $PROCESSED_COUNT, Failed: $FAIL_COUNT)"
    echo_log "(For individual file status, including skips of already downloaded items, please refer to the content of '$REMOTE_DOWNLOAD_ARCHIVE_FILE' and the destination directory '$REMOTE_INBOX_DIR'.)"

}

# Call main function with all script arguments
main "$@"

exit 0 