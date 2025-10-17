#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Check Droplet Queue Status
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Provides on-demand visibility into the Stentor droplet processing queue.
#   Displays formatted status of inbox, processing, completed, and failed items.
#   Manages remote directory mounting/unmounting intelligently.
#
# Features:
#   - Displays queue status with video counts and names
#   - Automatically mounts the remote directory if not already mounted
#   - Automatically unmounts after completion ONLY if mounted by this script
#   - Verbose mode for detailed output
#   - Clean, formatted output matching operational reporting standards
#
# Usage:
#   ./check_droplet_status.sh [options]
#
# Options:
#   -v, --verbose         Enable verbose output during status check
#   -h, --help            Display this help message and exit
#
# Dependencies:
#   - mount_droplet_yt.sh: (In script directory) Required for automatic mounting
#   - unmount_droplet_yt.sh: (In script directory) Required for automatic unmounting
#   - sshfs: Required by the mount/unmount scripts
#   - Standard Unix utilities: grep, wc, basename, ls
#
# Changelog:
#   1.0.0 - 2025-10-16 - Initial release with intelligent mount management
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

# --- Source Utilities ---
# Resolve the true directory of this script, even if it's a symlink
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
LOG_FILE_PATH="$HOME/.stentor/logs/check_droplet_status.log"

# * Global Variables and Configuration
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf"
HOME_STENTOR_DIR="$HOME/.stentor"
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf"

# Variables to be loaded from config
LOCAL_MOUNT_POINT=""

# Script state variables
SCRIPT_PERFORMED_MOUNT=false
VERBOSE=false

MOUNT_SCRIPT="$SCRIPT_DIR/mount_droplet_yt.sh"
UNMOUNT_SCRIPT="$SCRIPT_DIR/unmount_droplet_yt.sh"

# Ensure HOME_STENTOR_DIR exists
if [ ! -d "$HOME_STENTOR_DIR" ]; then
    mkdir -p "$HOME_STENTOR_DIR"
    if [ $? -ne 0 ]; then
        log_error "Error: Could not create $HOME_STENTOR_DIR."
        exit 1
    fi
fi

# The _is_mount_verified_and_responsive helper function was removed as its logic is now inlined into the main function for better clarity and to correctly implement the user's requirements.

# * Cleanup Function
cleanup() {
    local last_exit_status="$?"

    if [ "$SCRIPT_PERFORMED_MOUNT" = true ]; then
        if [ "$VERBOSE" = true ]; then
            print_info "Script performed mount, attempting to unmount..."
        fi
        if [ -x "$UNMOUNT_SCRIPT" ]; then
            if [ -n "$LOCAL_MOUNT_POINT" ]; then
                eval EXPANDED_LOCAL_MOUNT_POINT_CLEANUP="$LOCAL_MOUNT_POINT"
                if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"; then
                    if [ "$VERBOSE" = true ]; then
                        print_info "Calling unmount script: $UNMOUNT_SCRIPT for $EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"
                        print_info "Waiting 2 seconds before unmount to allow file operations to settle..."
                    fi
                    sleep 2
                    "$UNMOUNT_SCRIPT"
                    if [ $? -eq 0 ]; then
                        if [ "$VERBOSE" = true ]; then
                            print_info "Successfully unmounted '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script."
                        fi
                    else
                        log_error "Failed to unmount '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script. Manual unmount may be required."
                    fi
                else
                    if [ "$VERBOSE" = true ]; then
                        print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' is not currently mounted. No unmount needed by script."
                    fi
                fi
            else
                print_error "LOCAL_MOUNT_POINT is not set. Cannot attempt conditional unmount."
            fi
        else
            log_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot unmount automatically."
        fi
    fi

    if [ "$VERBOSE" = true ]; then
        print_info "Cleanup routine finished."
    fi
}

# Set trap for cleanup on EXIT or signals
trap cleanup EXIT INT TERM HUP

# * Usage Function
usage() {
    cat << EOF
Usage: $0 [options]

Checks the Stentor droplet processing queue status and displays formatted output.

Features:
  - Displays queue status for inbox, processing, completed, and failed items
  - Shows video counts and lists video names
  - Automatically mounts the remote directory if not already mounted
  - Automatically unmounts after completion ONLY if mounted by this script
  - Clean, formatted output

Options:
  -v, --verbose         Enable verbose output during status check
  -h, --help            Display this help message and exit

Configuration:
  The script reads configuration from stentor.conf in this order:
    1. $PROJECT_ENV_FILE
    2. $HOME_ENV_FILE

  Required variables in stentor.conf:
    - LOCAL_MOUNT_POINT: Where the droplet filesystem is mounted

Dependencies:
  - mount_droplet_yt.sh:  (In script directory) Required for automatic mounting
  - unmount_droplet_yt.sh:(In script directory) Required for automatic unmounting
  - sshfs:                Required by the mount/unmount scripts

Examples:
  # Check status using config defaults
  $0

  # Verbose mode for detailed progress
  $0 -v

Exit Codes:
  0: Success
  1: Missing dependencies or config error
  4: Mount failure
EOF
    exit 1
}

# * Argument Parsing
parse_arguments() {
    VERBOSE=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                ;;
            -h|--help)
                usage
                ;;
            -*)
                print_error "Unknown option '$1'"
                usage
                ;;
            *)
                print_error "Unexpected argument '$1'. This script does not take positional arguments."
                usage
                ;;
        esac
        shift
    done
}

# * Queue Status Functions
get_video_count() {
    local dir="$1"
    local count
    count=$(ls "$dir"/*.mp3 2>/dev/null | wc -l | xargs) || count="0"
    echo "$count"
}

get_file_count() {
    local dir="$1"
    local count
    count=$(ls "$dir" 2>/dev/null | wc -l | xargs) || count="0"
    echo "$count"
}

list_videos() {
    local dir="$1"
    ls "$dir"/*.mp3 2>/dev/null | while read -r file; do
        basename "$file" .mp3
    done || true
}

# * Main Script Logic
main() {
    parse_arguments "$@"

    if [ "$VERBOSE" = true ]; then
        print_step "Starting: Droplet Queue Status Check"
    fi

    # 1. Dependency checks
    if [ "$VERBOSE" = true ]; then
        print_info "Performing dependency checks..."
    fi

    if [ ! -x "$MOUNT_SCRIPT" ]; then
        print_error "Mount script not found or not executable: $MOUNT_SCRIPT"
        exit 1
    fi
    if [ "$VERBOSE" = true ]; then
        print_info "Mount script '$MOUNT_SCRIPT' found."
    fi

    if [ ! -x "$UNMOUNT_SCRIPT" ]; then
        print_error "Unmount script not found or not executable: $UNMOUNT_SCRIPT"
        exit 1
    fi
    if [ "$VERBOSE" = true ]; then
        print_info "Unmount script '$UNMOUNT_SCRIPT' found."
        print_info "Dependency checks passed."
    fi

    # 2. Load stentor.conf configuration
    if [ "$VERBOSE" = true ]; then
        print_info "Attempting to load stentor.conf configuration..."
    fi

    # Temporarily disable exit on unset variables to provide clearer errors
    set +u
    CONFIG_SOURCED=false
    if [ -f "$PROJECT_ENV_FILE" ]; then
        source "$PROJECT_ENV_FILE"
        CONFIG_SOURCED=true
        if [ "$VERBOSE" = true ]; then
            print_info "Loaded configuration from $PROJECT_ENV_FILE"
        fi
    elif [ -f "$HOME_ENV_FILE" ]; then
        source "$HOME_ENV_FILE"
        CONFIG_SOURCED=true
        if [ "$VERBOSE" = true ]; then
            print_info "Loaded configuration from $HOME_ENV_FILE"
        fi
    fi
    # Re-enable exit on unset variables
    set -u

    if [ "$CONFIG_SOURCED" = false ]; then
        print_error "Configuration file 'stentor.conf' not found."
        print_error "Please create one in the script directory or in ~/.stentor/."
        print_error "You can copy and rename 'stentor.conf.example' to get started."
        exit 1
    fi

    # 3. Validate required configuration variables
    if [ -z "${LOCAL_MOUNT_POINT:-}" ]; then
        print_error "Configuration Error: 'LOCAL_MOUNT_POINT' is not set in your stentor.conf file."
        print_error "Please define this variable to point to your droplet mount location."
        exit 1
    fi
    if [ "$VERBOSE" = true ]; then
        print_info "LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"
    fi

    # 4. Mount Management
    SCRIPT_PERFORMED_MOUNT=false
    eval EXPANDED_LOCAL_MOUNT_POINT="$LOCAL_MOUNT_POINT"

    if [ "$VERBOSE" = true ]; then
        print_info "Checking mount status for '$EXPANDED_LOCAL_MOUNT_POINT'..."
    fi

    # 4. Mount Management - Per user instruction: Mount if not mounted, error if stale.
    eval EXPANDED_LOCAL_MOUNT_POINT="$LOCAL_MOUNT_POINT"
    SCRIPT_PERFORMED_MOUNT=false

    # Check if the mount point is listed in the system's mount table
    if ! mount | grep -q " on $EXPANDED_LOCAL_MOUNT_POINT "; then
        # --- Case 1: NOT MOUNTED ---
        # Per user: "NOT MOUNTED MEANS MOUNT AND LATER UNMOUNT."
        print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT' is not mounted. Attempting to mount..."
        
        if [ -x "$MOUNT_SCRIPT" ]; then
            "$MOUNT_SCRIPT"
            mount_exit_code=$?
            if [ $mount_exit_code -eq 0 ]; then
                sleep 2 # Allow time for the mount to stabilize before checking it.
                
                # Verify it's now mounted AND responsive
                if mount | grep -q " on $EXPANDED_LOCAL_MOUNT_POINT " && ls -A -1 "$EXPANDED_LOCAL_MOUNT_POINT" >/dev/null 2>&1; then
                    print_info "Successfully mounted and verified '$EXPANDED_LOCAL_MOUNT_POINT'."
                    SCRIPT_PERFORMED_MOUNT=true # This flag tells the cleanup function to unmount later.
                else
                    print_error "Failed: Mount verification failed for '$EXPANDED_LOCAL_MOUNT_POINT' after mount attempt."
                    print_error "The mount script ran, but the mount point is still not responsive."
                    exit 4
                fi
            else
                print_error "Failed: Mount script '$MOUNT_SCRIPT' failed with exit code $mount_exit_code."
                exit 4
            fi
        else
            print_error "Failed: Mount script '$MOUNT_SCRIPT' not found or not executable."
            exit 1
        fi
    else
        # --- Case 2: MOUNTED ---
        # Now check if it's responsive or stale.
        if ! ls -A -1 "$EXPANDED_LOCAL_MOUNT_POINT" >/dev/null 2>&1; then
            # --- STALE mount ---
            # Per user: "STALE MEANS PRINT AND LOG AN EXPLANATION"
            print_error "Mount point '$EXPANDED_LOCAL_MOUNT_POINT' is stale and unresponsive."
            print_error "The drive is listed as mounted by the OS, but is not accessible."
            print_error "Please manually run './scripts/client-side/unmount_droplet_yt.sh' and try again."
            exit 4
        else
            # --- HEALTHY mount ---
            if [ "$VERBOSE" = true ]; then
                print_info "Mount '$EXPANDED_LOCAL_MOUNT_POINT' is already active and responsive."
            fi
        fi
    fi

    # 5. Check queue status
    INBOX_DIR="${EXPANDED_LOCAL_MOUNT_POINT}/inbox"
    PROCESSING_DIR="${EXPANDED_LOCAL_MOUNT_POINT}/processing"
    COMPLETED_DIR="${EXPANDED_LOCAL_MOUNT_POINT}/completed"
    FAILED_DIR="${EXPANDED_LOCAL_MOUNT_POINT}/failed"

    # Verify directories exist
    for dir in "$INBOX_DIR" "$PROCESSING_DIR" "$COMPLETED_DIR" "$FAILED_DIR"; do
        if [ ! -d "$dir" ]; then
            print_error "Required directory does not exist: $dir"
            print_error "Check that the remote filesystem structure is correct."
            exit 1
        fi
    done

    # Test accessibility
    if [ "$VERBOSE" = true ]; then
        print_info "Testing accessibility of queue directories..."
    fi
    if ! ls -A "$INBOX_DIR" >/dev/null 2>&1; then
        print_error "Queue directories exist but are not accessible (possibly stale mount)"
        print_error "Try unmounting and remounting: $UNMOUNT_SCRIPT && $MOUNT_SCRIPT"
        exit 4
    fi
    if [ "$VERBOSE" = true ]; then
        print_info "Queue directories are accessible."
    fi

    # 6. Gather statistics
    INBOX_VIDEO_COUNT=$(get_video_count "$INBOX_DIR")
    INBOX_FILE_COUNT=$(get_file_count "$INBOX_DIR")
    PROCESSING_VIDEO_COUNT=$(get_video_count "$PROCESSING_DIR")
    PROCESSING_FILE_COUNT=$(get_file_count "$PROCESSING_DIR")
    COMPLETED_FILE_COUNT=$(get_file_count "$COMPLETED_DIR")
    COMPLETED_TRANSCRIPT_COUNT=$(ls "$COMPLETED_DIR"/*.txt 2>/dev/null | wc -l | xargs)
    FAILED_VIDEO_COUNT=$(get_video_count "$FAILED_DIR")
    FAILED_FILE_COUNT=$(get_file_count "$FAILED_DIR")

    # 7. Display formatted output
    print_separator
    print_header "Droplet Queue Status"

    # INBOX
    print_info "INBOX: $INBOX_VIDEO_COUNT video(s) ($INBOX_FILE_COUNT total files)"
    if [ "$INBOX_VIDEO_COUNT" -gt 0 ]; then
        list_videos "$INBOX_DIR" | while read -r video; do
            print_info "  - $video"
        done
    fi

    # PROCESSING
    print_info "PROCESSING: $PROCESSING_VIDEO_COUNT video(s) ($PROCESSING_FILE_COUNT total files)"
    if [ "$PROCESSING_VIDEO_COUNT" -gt 0 ]; then
        list_videos "$PROCESSING_DIR" | while read -r video; do
            print_info "  - $video"
            # Check for lock file
            if ls "$PROCESSING_DIR"/*.mp3.out.* 2>/dev/null | grep -q .; then
                print_info "    [Active processing lock detected]"
            fi
        done
    fi

    # COMPLETED
    print_info "COMPLETED: $COMPLETED_TRANSCRIPT_COUNT video(s) ($COMPLETED_FILE_COUNT total files)"
    print_info "  - $COMPLETED_TRANSCRIPT_COUNT transcript files (.txt)"
    print_info "  - $COMPLETED_FILE_COUNT total files (includes transcripts plus metadata)"

    # FAILED
    print_info "FAILED: $FAILED_VIDEO_COUNT video(s) ($FAILED_FILE_COUNT total files)"
    if [ "$FAILED_VIDEO_COUNT" -gt 0 ]; then
        counter=1
        list_videos "$FAILED_DIR" | while read -r video; do
            print_info "  $counter. $video"
            counter=$((counter + 1))
        done
    fi

    print_footer
    print_completed "Droplet Queue Status Check"
}

# Run main function with all script arguments
main "$@"
