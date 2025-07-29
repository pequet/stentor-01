#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Harvest YouTube Videos to Stentor
# █ ███   Version: 1.1.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Periodically harvests content from a list of URLs (defined in
#   a user-provided file) and queues them for processing using
#   the download_to_stentor.sh script.
#
# Features:
#   - Reads URLs from a source file provided as an argument.
#   - Supports comments in the source file (lines starting with # or text after |).
#   - Calls download_to_stentor.sh for each valid URL.
#   - Ensures only one instance runs at a time using a lock file.
#   - Logs activity to ~/.stentor/logs/periodic_harvester.log.
#
# Usage:
#   ./periodic_harvester.sh /path/to/your/content_sources.txt
#   ./periodic_harvester.sh /path/to/your/content_sources.txt --use-break-on-existing
#   Typically run via cron.
#
# Usage (with config file):
#   ./periodic_harvester.sh /path/to/your/harvester.conf
#
#   The config file should define the CONTENT_SOURCES_FILE variable. Example:
#   CONTENT_SOURCES_FILE="$HOME/.stentor/daily_youtube_channels.txt"
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
#   1.1.0 - 2025-07-29 - Added logging and messaging utilities.
#   1.0.0 - 2025-05-25 - Initial release with URL harvesting and download script integration.
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

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
LOG_FILE_PATH="$HOME/.stentor/logs/periodic_harvester.log"

# * Global Variables and Configuration
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf" # For loading LOCAL_MOUNT_POINT
HOME_STENTOR_DIR="$HOME/.stentor" # Used for stentor.conf and lock files
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf" # For loading LOCAL_MOUNT_POINT

LOCK_FILE="$HOME/.stentor/periodic_harvester.lock"
LOCK_TIMEOUT=300  # 300 seconds timeout
CONTENT_SOURCES_FILE="" # NOW PROVIDED AS A SCRIPT ARGUMENT
DOWNLOAD_SCRIPT="$(dirname "$0")/download_to_stentor.sh"
LOCK_ACQUIRED_BY_THIS_PROCESS=false # Flag to track if this instance acquired the lock

LOCAL_MOUNT_POINT="" # Will be loaded from stentor.conf
HARVESTER_PERFORMED_MOUNT=false # To track if this script mounted

MOUNT_SCRIPT="$SCRIPT_DIR/mount_droplet_yt.sh" # Assumes it's in the same dir
UNMOUNT_SCRIPT="$SCRIPT_DIR/unmount_droplet_yt.sh" # Assumes it's in the same dir

# * Lock Management

# Note: in order to test the mechanism,k run this command:
# LOCK_FILE_PATH="$HOME/.stentor/periodic_harvester.lock"; mkdir -p "$(dirname "$LOCK_FILE_PATH")"; print_debug "$$" > "$LOCK_FILE_PATH"; print_debug "Artificial lock file created at $LOCK_FILE_PATH with PID $$"

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        local lock_file_age_info="(age not calculated)"
        local lock_file_age_seconds=-1

        print_debug "Lock file found: $LOCK_FILE" >&2
        print_debug "Content of LOCK_FILE (PID read): '$lock_pid'" >&2

        local current_time=$(date +%s)
        local file_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)

        if [[ -n "$file_mod_time" ]]; then
            lock_file_age_seconds=$((current_time - file_mod_time))
            lock_file_age_info="(Age: ${lock_file_age_seconds}s, Timeout: ${LOCK_TIMEOUT}s)"
            print_debug "Calculated lock_file_age_seconds: $lock_file_age_seconds" >&2
            print_debug "LOCK_TIMEOUT: $LOCK_TIMEOUT" >&2
            print_debug "Formatted lock_file_age_info: $lock_file_age_info" >&2
        else
            lock_file_age_info="(could not determine age)"
            print_debug "Could not determine file_mod_time. lock_file_age_seconds remains $lock_file_age_seconds." >&2
        fi

        local pid_check_command_exit_code
        if [[ -n "$lock_pid" ]]; then
            print_debug "Preparing to check PID $lock_pid with 'kill -0 $lock_pid'" >&2
            kill -0 "$lock_pid" 2>/dev/null
            pid_check_command_exit_code=$?
            print_debug "'kill -0 $lock_pid' exit code: $pid_check_command_exit_code" >&2
        else
            print_debug "lock_pid is empty. Assuming PID not running." >&2
            pid_check_command_exit_code=1 # Simulate PID not running if lock_pid is empty
        fi

        if [[ "$pid_check_command_exit_code" -eq 0 ]]; then
            print_debug "BRANCH TAKEN: PID $lock_pid IS considered RUNNING." >&2
            print_warning "Another harvester instance is running (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
            return 1
        else
            print_debug "BRANCH TAKEN: PID $lock_pid IS considered NOT RUNNING (or PID was empty)." >&2
            if [[ "$lock_file_age_seconds" -ne -1 ]]; then # Age was successfully calculated
                print_debug "Comparing age: $lock_file_age_seconds > $LOCK_TIMEOUT ?" >&2
                if [[ "$lock_file_age_seconds" -gt "$LOCK_TIMEOUT" ]]; then
                    print_debug "AGE COMPARISON TRUE. Lock IS STALE." >&2
                    print_info "Removing stale lock file (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
                    rm -f "$LOCK_FILE"
                else
                    print_debug "AGE COMPARISON FALSE. Lock IS NOT STALE ENOUGH." >&2
                    print_warning "Lock file (PID: $lock_pid) exists but is not older than timeout. Details: $lock_file_age_info. Not removing. Lock file: $LOCK_FILE"
                    return 1
                fi
            else # Age could not be determined earlier
                print_debug "Age could not be calculated. Assuming stale and removing." >&2
                print_warning "Could not determine age of lock file (PID: $lock_pid). Details: $lock_file_age_info. Assuming stale and removing. Lock file: $LOCK_FILE"
                rm -f "$LOCK_FILE"
            fi
        fi
    fi
    
    print_debug "Proceeding to create new lock file." >&2
    mkdir -p "$(dirname "$LOCK_FILE")"
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED_BY_THIS_PROCESS=true # Set flag as lock is acquired by this process
    return 0
}

release_lock() {
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        print_debug "release_lock called by owning process (PID: $$). Removing $LOCK_FILE" >&2
        rm -f "$LOCK_FILE"
    else
        print_debug "release_lock called, but lock not owned by this process (PID: $$). Lock file $LOCK_FILE not removed by this instance." >&2
    fi
}

# * Config Loading Function
load_harvester_config() {
    local config_file="$1"
    if [ ! -f "$config_file" ]; then
        print_error "Harvester configuration file not found at '$config_file'."
        print_error "Failed: Harvester config file not found: $config_file"
        return 1
    fi

    print_info "Loading harvester configuration from: $config_file"
    # shellcheck source=/dev/null
    source "$config_file"

    if [ -z "${CONTENT_SOURCES_FILE:-}" ] || [ ! -f "${CONTENT_SOURCES_FILE}" ]; then
        print_error "CONTENT_SOURCES_FILE is not defined in '$config_file' or the specified file does not exist."
        print_error "Failed: CONTENT_SOURCES_FILE not configured or invalid in $config_file"
        return 1
    fi

    print_info "Content sources file set to: $CONTENT_SOURCES_FILE"
    return 0
}


# * Mount Management Functions
load_env_config() {
    print_info "Attempting to load stentor.conf configuration for mount point..."
    CONFIG_SOURCED=false
    if [ -f "$PROJECT_ENV_FILE" ]; then
        print_info "Found project stentor.conf file: $PROJECT_ENV_FILE. Sourcing..."
        # shellcheck source=./stentor.conf
        source "$PROJECT_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}"
        print_info "Loaded configuration from $PROJECT_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    elif [ -f "$HOME_ENV_FILE" ]; then
        print_info "Found home stentor.conf file: $HOME_ENV_FILE. Sourcing..."
        # shellcheck source=~/.stentor/stentor.conf
        source "$HOME_ENV_FILE"
        CONFIG_SOURCED=true
        LOCAL_MOUNT_POINT="${LOCAL_MOUNT_POINT:-}"
        print_info "Loaded configuration from $HOME_ENV_FILE. LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    else
        print_info "No stentor.conf file found at $PROJECT_ENV_FILE or $HOME_ENV_FILE."
    fi

    if [ ! "$CONFIG_SOURCED" = true ] || [ -z "$LOCAL_MOUNT_POINT" ]; then
        print_warning "LOCAL_MOUNT_POINT not configured in stentor.conf or stentor.conf not found. Mount/unmount operations will be skipped by harvester."
        LOCAL_MOUNT_POINT="" # Ensure it's empty to prevent unintended logic
    fi
}

ensure_mount_point_ready() {
    if [ -z "$LOCAL_MOUNT_POINT" ]; then
        print_info "LOCAL_MOUNT_POINT not defined. Skipping mount check by harvester."
        return 0 # Nothing to do
    fi

    print_info "Checking mount point: '$LOCAL_MOUNT_POINT'"
    eval EXPANDED_LOCAL_MOUNT_POINT_CHECK="$LOCAL_MOUNT_POINT" # Expand tilde if any

    if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CHECK"; then
        print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' is already mounted."
    else
        print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' is not mounted. Attempting to mount..."
        if [ ! -x "$MOUNT_SCRIPT" ]; then
            print_error "Mount script '$MOUNT_SCRIPT' not found or not executable."
            print_error "Failed: Mount script $MOUNT_SCRIPT not found/executable"
            # Not exiting, as download_to_stentor might handle it or download locally
            return 1 # Indicate mount attempt failed
        fi

        "$MOUNT_SCRIPT"
        if [ $? -eq 0 ]; then
            print_info "Successfully mounted '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' via $MOUNT_SCRIPT."
            HARVESTER_PERFORMED_MOUNT=true
        else
            print_error "Failed to mount '$EXPANDED_LOCAL_MOUNT_POINT_CHECK' via $MOUNT_SCRIPT."
            print_error "Failed: Mount of $EXPANDED_LOCAL_MOUNT_POINT_CHECK via $MOUNT_SCRIPT"
            # Not exiting immediately, allow download_to_stentor to make its own decisions
            # This script might still be able to process URLs if download_to_stentor can use a different destination
            return 1 # Indicate mount attempt failed
        fi
    fi
    return 0
}

# * Cleanup Function
cleanup_harvester() {
    print_step "Executing harvester cleanup routine"
    release_lock # Release the script's own lock file

    if [ "$HARVESTER_PERFORMED_MOUNT" = true ]; then
        print_info "Harvester performed mount, attempting to unmount '$LOCAL_MOUNT_POINT'..."
        if [ -x "$UNMOUNT_SCRIPT" ]; then
            eval EXPANDED_LOCAL_MOUNT_POINT_CLEANUP="$LOCAL_MOUNT_POINT"
            if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"; then
                print_info "Calling unmount script: $UNMOUNT_SCRIPT for $EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"
                print_info "Waiting 2 seconds before unmount to allow file operations to settle..."
                sleep 2
                "$UNMOUNT_SCRIPT"
                if [ $? -eq 0 ]; then
                    print_info "Successfully unmounted '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script."
                else
                    print_error "Failed to unmount '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script. Manual unmount may be required."
                fi
            else
                print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' is not currently mounted. No unmount needed by harvester."
            fi
        else
            print_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot unmount automatically."
        fi
    else
        print_info "Harvester did not perform mount, or mount point not specified for unmount. No unmount action taken by harvester."
    fi
    print_info "Harvester cleanup routine finished."
}

# * Content Processing
process_content_sources() {
    local pass_break_on_existing_flag=$1 # Receive the flag state

    if [[ ! -f "$CONTENT_SOURCES_FILE" ]]; then
        print_warning "Content sources file not found: $CONTENT_SOURCES_FILE"
        print_info "This should have been checked during config load, but re-verifying."
        return 1 # Return an error code now
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
        
        print_info "Processing: $url${comment:+ ($comment)}"
        
        if [[ -x "$DOWNLOAD_SCRIPT" ]]; then
            local download_cmd_args=()
            if [ "$pass_break_on_existing_flag" = true ]; then
                download_cmd_args+=("-B")
            fi
            download_cmd_args+=("$url")

            if "$DOWNLOAD_SCRIPT" "${download_cmd_args[@]}"; then
                print_info "Successfully queued: $url"
                ((processed++))
            else
                print_error "Failed to download: $url"
                ((failed++))
            fi
        else
            print_error "Download script not found or not executable: $DOWNLOAD_SCRIPT"
            ((failed++))
        fi
        
    done < "$CONTENT_SOURCES_FILE"
    
    print_info "Harvest complete: $processed processed, $skipped skipped, $failed failed"
    return 0 # Indicate success
}

# * Setup
setup_directories() {
    # This function now ensures the log directory from the sourced utility exists.
    ensure_log_directory
}

# * Main Function
main() {
    local use_break_on_existing_for_download=false # Local variable for the flag state

    # --- Argument Parsing ---
    if [ "$#" -eq 0 ]; then
        print_error "Usage: $0 /path/to/content_sources.txt [--use-break-on-existing]"
        exit 1
    fi

    CONTENT_SOURCES_FILE="$1"
    if [ ! -f "$CONTENT_SOURCES_FILE" ]; then
        print_error "Failed: Content sources file not found at '$CONTENT_SOURCES_FILE'"
        exit 1
    fi
    shift # The first argument is the file

    # Simple argument parsing for -B or --use-break-on-existing
    for arg in "$@"; do
        case $arg in
            -B|--use-break-on-existing)
            use_break_on_existing_for_download=true
            ;;
            # Potentially handle other arguments or --help here in the future
        esac
    done

    setup_directories

    print_step "Starting: Periodic Harvester for source file: $(basename "$CONTENT_SOURCES_FILE")${use_break_on_existing_for_download:+ (Using --break-on-existing for downloads)}"

    # Acquire lock
    if ! acquire_lock; then
        print_error "Failed: Could not acquire lock (another instance may be running or stale lock)"
        exit 1
    fi
    
    # Ensure lock is released and potential mount is cleaned up on exit
    trap cleanup_harvester EXIT INT TERM HUP
    
    # Load stentor.conf configuration for LOCAL_MOUNT_POINT
    load_env_config

    # Attempt to mount the remote directory if configured and not already mounted
    # If LOCAL_MOUNT_POINT is not set, this function will do nothing.
    # If mount fails, it logs but doesn't exit, allowing download_to_stentor to try.
    ensure_mount_point_ready

    # Check if download script exists
    if [[ ! -f "$DOWNLOAD_SCRIPT" ]]; then
        print_error "Download script not found: $DOWNLOAD_SCRIPT"
        print_error "Failed: Download script not found at $DOWNLOAD_SCRIPT"
        exit 2
    fi
    
    # Process content sources
    if ! process_content_sources "$use_break_on_existing_for_download"; then
        print_error "Harvest failed. Check logs for details: $LOG_FILE_PATH"
        # The trap will handle cleanup, so we can just exit.
        exit 1
    fi
    
    print_success "Completed: Periodic Harvester"
}

# Run main function
main "$@" 