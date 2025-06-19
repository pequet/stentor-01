#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Harvest YouTube Videos to Stentor
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Periodically harvests content from a list of URLs (defined in
#   ~/.stentor/content_sources.txt) and queues them for processing using
#   the download_to_stentor.sh script.
#
# Features:
#   - Reads URLs from a configurable source file.
#   - Supports comments in the source file (lines starting with # or text after |).
#   - Calls download_to_stentor.sh for each valid URL.
#   - Ensures only one instance runs at a time using a lock file.
#   - Logs activity to ~/.stentor/logs/periodic_harvester.log.
#
# Usage:
#   ./periodic_harvester.sh
#   ./periodic_harvester.sh --use-break-on-existing
#   Typically run via cron.
#
# Dependencies:
#   - download_to_stentor.sh: Script used to download and queue content.
#   - Standard Unix utilities: date, cat, stat, kill, rm, mkdir, xargs, tee.
#
# Content Sources File Format (~/.stentor/content_sources.txt):
#   Each line should contain a URL. Optional comments can be added after a | character.
#   Example:
#     https://www.youtube.com/watch?v=dQw4w9WgXcQ
#     https://www.youtube.com/playlist?list=PLexample|My Example Playlist
#     # This is a comment line and will be ignored
#
# Changelog:
#   1.0.0 - 2025-05-25 - Initial release with URL harvesting and download script integration.
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

# * Source Utilities
source "$(dirname "$0")/../utils/messaging_utils.sh"

# * Global Variables and Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)" # Added for clarity and .env path
PROJECT_ENV_FILE="$SCRIPT_DIR/.env" # For loading LOCAL_MOUNT_POINT
HOME_STENTOR_DIR="$HOME/.stentor" # Used for .env and lock files
HOME_ENV_FILE="$HOME_STENTOR_DIR/.env" # For loading LOCAL_MOUNT_POINT

LOCK_FILE="$HOME/.stentor/periodic_harvester.lock"
LOCK_TIMEOUT=300  # 300 seconds timeout
CONTENT_SOURCES_FILE="$HOME/.stentor/content_sources.txt"
DOWNLOAD_SCRIPT="$(dirname "$0")/download_to_stentor.sh"
LOG_FILE="$HOME/.stentor/logs/periodic_harvester.log"
LOCK_ACQUIRED_BY_THIS_PROCESS=false # Flag to track if this instance acquired the lock

LOCAL_MOUNT_POINT="" # Will be loaded from .env
HARVESTER_PERFORMED_MOUNT=false # To track if this script mounted

MOUNT_SCRIPT="$SCRIPT_DIR/mount_droplet_yt.sh" # Assumes it's in the same dir
UNMOUNT_SCRIPT="$SCRIPT_DIR/unmount_droplet_yt.sh" # Assumes it's in the same dir

# * Logging Functions
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { log_message "INFO" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }

# * Lock Management

# Note: in order to test the mechanism,k run this command:
# LOCK_FILE_PATH="$HOME/.stentor/periodic_harvester.lock"; mkdir -p "$(dirname "$LOCK_FILE_PATH")"; echo "$$" > "$LOCK_FILE_PATH"; echo "Artificial lock file created at $LOCK_FILE_PATH with PID $$"

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
            log_warn "Another harvester instance is running (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
            echo "--- DEBUG LOCK END (PID RUNNING) ---" >&2
            return 1
        else
            echo "DEBUG BRANCH TAKEN: PID $lock_pid IS considered NOT RUNNING (or PID was empty)." >&2
            if [[ "$lock_file_age_seconds" -ne -1 ]]; then # Age was successfully calculated
                echo "DEBUG: Comparing age: $lock_file_age_seconds > $LOCK_TIMEOUT ?" >&2
                if [[ "$lock_file_age_seconds" -gt "$LOCK_TIMEOUT" ]]; then
                    echo "DEBUG: AGE COMPARISON TRUE. Lock IS STALE." >&2
                    log_info "Removing stale lock file (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
                    rm -f "$LOCK_FILE"
                else
                    echo "DEBUG: AGE COMPARISON FALSE. Lock IS NOT STALE ENOUGH." >&2
                    log_warn "Lock file (PID: $lock_pid) exists but is not older than timeout. Details: $lock_file_age_info. Not removing. Lock file: $LOCK_FILE"
                    echo "--- DEBUG LOCK END (PID NOT RUNNING, NOT STALE ENOUGH) ---" >&2
                    return 1
                fi
            else # Age could not be determined earlier
                echo "DEBUG: Age could not be calculated. Assuming stale and removing." >&2
                log_warn "Could not determine age of lock file (PID: $lock_pid). Details: $lock_file_age_info. Assuming stale and removing. Lock file: $LOCK_FILE"
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

# * Mount Management Functions
load_env_config() {
    log_info "Attempting to load .env configuration for mount point..."
    CONFIG_SOURCED=false
    if [ -f "$PROJECT_ENV_FILE" ]; then
        log_info "Found project .env file: $PROJECT_ENV_FILE. Sourcing..."
        # shellcheck source=./.env
        source "$PROJECT_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}"
        log_info "Loaded configuration from $PROJECT_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    elif [ -f "$HOME_ENV_FILE" ]; then
        log_info "Found home .env file: $HOME_ENV_FILE. Sourcing..."
        # shellcheck source=~/.stentor/.env
        source "$HOME_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}"
        log_info "Loaded configuration from $HOME_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    else
        log_info "No .env file found at $PROJECT_ENV_FILE or $HOME_ENV_FILE."
    fi

    if [ ! "$CONFIG_SOURCED" = true ] || [ -z "$LOCAL_MOUNT_POINT" ]; then
        log_warn "LOCAL_MOUNT_POINT not configured in .env or .env not found. Mount/unmount operations will be skipped by harvester."
        LOCAL_MOUNT_POINT="" # Ensure it's empty to prevent unintended logic
    fi
}

ensure_mount_point_ready() {
    if [ -z "$LOCAL_MOUNT_POINT" ]; then
        log_info "LOCAL_MOUNT_POINT not defined. Skipping mount check by harvester."
        return 0 # Nothing to do
    fi

    log_info "Checking mount point: '$LOCAL_MOUNT_POINT'"
    eval EXPANDED_LOCAL_MOUNT_POINT_CHECK="$LOCAL_MOUNT_POINT" # Expand tilde if any

    if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CHECK"; then
        log_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' is already mounted."
    else
        log_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' is not mounted. Attempting to mount..."
        if [ ! -x "$MOUNT_SCRIPT" ]; then
            log_error "Mount script '$MOUNT_SCRIPT' not found or not executable."
            display_status_message "!" "Failed: Mount script $MOUNT_SCRIPT not found/executable"
            # Not exiting, as download_to_stentor might handle it or download locally
            return 1 # Indicate mount attempt failed
        fi

        "$MOUNT_SCRIPT"
        if [ $? -eq 0 ]; then
            log_info "Successfully mounted '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' via $MOUNT_SCRIPT."
            HARVESTER_PERFORMED_MOUNT=true
        else
            log_error "Failed to mount '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' via $MOUNT_SCRIPT."
            display_status_message "!" "Failed: Mount of $EXPANDED_LOCAL_MOUNT_POINT_CHECK via $MOUNT_SCRIPT"
            # Not exiting immediately, allow download_to_stentor to make its own decisions
            # This script might still be able to process URLs if download_to_stentor can use a different destination
            return 1 # Indicate mount attempt failed
        fi
    fi
    return 0
}

# * Cleanup Function
cleanup_harvester() {
    display_status_message "i" "Info: Executing harvester cleanup routine"
    release_lock # Release the script's own lock file

    if [ "$HARVESTER_PERFORMED_MOUNT" = true ]; then
        log_info "Harvester performed mount, attempting to unmount '$LOCAL_MOUNT_POINT'..."
        if [ -x "$UNMOUNT_SCRIPT" ]; then
            eval EXPANDED_LOCAL_MOUNT_POINT_CLEANUP="$LOCAL_MOUNT_POINT"
            if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"; then
                log_info "Calling unmount script: $UNMOUNT_SCRIPT for $EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"
                log_info "Waiting 2 seconds before unmount to allow file operations to settle..."
                sleep 2
                "$UNMOUNT_SCRIPT"
                if [ $? -eq 0 ]; then
                    log_info "Successfully unmounted '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script."
                else
                    log_error "Failed to unmount '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script. Manual unmount may be required."
                fi
            else
                log_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' is not currently mounted. No unmount needed by harvester."
            fi
        else
            log_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot unmount automatically."
        fi
    else
        log_info "Harvester did not perform mount, or mount point not specified for unmount. No unmount action taken by harvester."
    fi
    log_info "Harvester cleanup routine finished."
}

# * Content Processing
process_content_sources() {
    local pass_break_on_existing_flag=$1 # Receive the flag state

    if [[ ! -f "$CONTENT_SOURCES_FILE" ]]; then
        log_warn "Content sources file not found: $CONTENT_SOURCES_FILE"
        log_info "Create it with URLs, one per line. Optional comments after |"
        log_info "Example:"
        log_info "  https://youtube.com/watch?v=xxx"
        log_info "  https://youtube.com/playlist?list=xxx|My Playlist"
        return 0
    fi
    
    local processed=0
    local skipped=0
    local failed=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Extract URL (everything before |)
        local url="${line%%|*}"
        url=$(echo "$url" | xargs)  # trim whitespace
        
        # Extract comment (everything after |)
        local comment=""
        if [[ "$line" == *"|"* ]]; then
            comment="${line#*|}"
            comment=$(echo "$comment" | xargs)  # trim whitespace
        fi
        
        if [[ -z "$url" ]]; then
            ((skipped++))
            continue
        fi
        
        log_info "Processing: $url${comment:+ ($comment)}"
        
        if [[ -x "$DOWNLOAD_SCRIPT" ]]; then
            local download_cmd_args=()
            if [ "$pass_break_on_existing_flag" = true ]; then
                download_cmd_args+=("-B")
            fi
            download_cmd_args+=("$url")

            if "$DOWNLOAD_SCRIPT" "${download_cmd_args[@]}"; then
                log_info "Successfully queued: $url"
                ((processed++))
            else
                log_error "Failed to download: $url"
                ((failed++))
            fi
        else
            log_error "Download script not found or not executable: $DOWNLOAD_SCRIPT"
            ((failed++))
        fi
        
    done < "$CONTENT_SOURCES_FILE"
    
    display_status_message "i" "Harvest complete: $processed processed, $skipped skipped, $failed failed"
}

# * Setup
setup_directories() {
    mkdir -p "$HOME/.stentor/logs"
}

# * Main Function
main() {
    local use_break_on_existing_for_download=false # Local variable for the flag state

    # Simple argument parsing for -B or --use-break-on-existing
    for arg in "$@"; do
        case $arg in
            -B|--use-break-on-existing)
            use_break_on_existing_for_download=true
            shift # Remove the flag from arguments passed to subsequent logic if any
            ;;
            # Potentially handle other arguments or --help here in the future
        esac
    done

    setup_directories
    
    display_status_message " " "Starting: Periodic Harvester${use_break_on_existing_for_download:+
    (Using --break-on-existing for downloads)}" # Append to message if true
    
    # Acquire lock
    if ! acquire_lock; then
        display_status_message "!" "Failed: Could not acquire lock (another instance may be running or stale lock)"
        exit 1
    fi
    
    # Ensure lock is released and potential mount is cleaned up on exit
    trap cleanup_harvester EXIT INT TERM HUP
    
    # Load .env configuration for LOCAL_MOUNT_POINT
    load_env_config

    # Attempt to mount the remote directory if configured and not already mounted
    # If LOCAL_MOUNT_POINT is not set, this function will do nothing.
    # If mount fails, it logs but doesn't exit, allowing download_to_stentor to try.
    ensure_mount_point_ready

    # Check if download script exists
    if [[ ! -f "$DOWNLOAD_SCRIPT" ]]; then
        log_error "Download script not found: $DOWNLOAD_SCRIPT"
        display_status_message "!" "Failed: Download script not found at $DOWNLOAD_SCRIPT"
        exit 2
    fi
    
    # Process content sources
    process_content_sources "$use_break_on_existing_for_download" # Pass flag state to the function
    
    display_status_message "x" "Completed: Periodic Harvester"
}

# Run main function
main "$@" 