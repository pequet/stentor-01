#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Retrieve Completed Transcripts from Droplet
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Retrieves completed transcript files from the Stentor droplet to local storage.
#   Uses an archive mechanism to prevent re-copying files that have already been retrieved.
#   Manages remote directory mounting/unmounting if configured.
#
# Features:
#   - Copies completed transcripts from droplet to local directory
#   - Uses retrieval archive to prevent re-copying (similar to yt-dlp's --download-archive)
#   - Automatically mounts the remote directory if not already mounted
#   - Automatically unmounts after completion ONLY if mounted by this script
#   - Allows override of destination directory via command-line argument
#   - Destination directory must exist (will not be created automatically)
#   - Progress reporting during retrieval
#
# Usage:
#   ./retrieve_transcripts.sh [options]
#
# Options:
#   -d, --destination DIR  Override LOCAL_TRANSCRIPT_DIR from config
#                          Directory must already exist (script will not create it)
#   -n, --dry-run         Show what would be retrieved without copying
#   -v, --verbose         Enable verbose output during retrieval
#   -h, --help            Display this help message and exit
#
# Dependencies:
#   - mount_droplet_yt.sh: (In script directory) Required for automatic mounting
#   - unmount_droplet_yt.sh: (In script directory) Required for automatic unmounting
#   - sshfs: Required by the mount/unmount scripts
#   - Standard Unix utilities: basename, cp, grep, date, du, wc, mkdir
#
# Changelog:
#   1.0.0 - 2025-10-16 - Initial release with archive-based retrieval mechanism
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
LOG_FILE_PATH="$HOME/.stentor/logs/retrieve_transcripts.log"

# * Global Variables and Configuration
PROJECT_ENV_FILE="$SCRIPT_DIR/stentor.conf"
HOME_STENTOR_DIR="$HOME/.stentor"
HOME_ENV_FILE="$HOME_STENTOR_DIR/stentor.conf"

# Variables to be loaded from config
LOCAL_MOUNT_POINT=""
LOCAL_TRANSCRIPT_DIR=""

# Script state variables
SCRIPT_PERFORMED_MOUNT=false
DESTINATION_OVERRIDE=""
FINAL_DESTINATION_DIR=""
DRY_RUN=false
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

# * Helper Function: Verify Mount Point
_is_mount_verified_and_responsive() {
    local mount_path_to_check="$1"
    print_info "Verifying mount: Step 1 - Checking OS mount table for '$mount_path_to_check'..."
    if ! mount | grep -q " on $mount_path_to_check "; then
        print_info "Verification Step 1 FAILED: '$mount_path_to_check' not found in 'mount' output."
        return 1
    fi
    print_info "Verification Step 1 PASSED: '$mount_path_to_check' found in OS mount table."

    print_info "Verifying mount: Step 2 - Checking responsiveness of '$mount_path_to_check'..."
    if ! ls -A -1 "$mount_path_to_check" >/dev/null 2>&1; then
        log_error "Verification Step 2 FAILED: Mount point '$mount_path_to_check' is not responsive or accessible."
        return 1
    fi
    print_info "Verification Step 2 PASSED: Mount point '$mount_path_to_check' is responsive."
    return 0
}

# * Cleanup Function
cleanup() {
    local last_exit_status="$?"

    if [ "$SCRIPT_PERFORMED_MOUNT" = true ]; then
        print_info "Script performed mount, attempting to unmount..."
        if [ -x "$UNMOUNT_SCRIPT" ]; then
            if [ -n "$LOCAL_MOUNT_POINT" ]; then
                eval EXPANDED_LOCAL_MOUNT_POINT_CLEANUP="$LOCAL_MOUNT_POINT"
                if mount | grep -q "$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"; then
                    print_info "Calling unmount script: $UNMOUNT_SCRIPT for $EXPANDED_LOCAL_MOUNT_POINT_CLEANUP"
                    print_info "Waiting 2 seconds before unmount to allow file operations to settle..."
                    sleep 2
                    "$UNMOUNT_SCRIPT"
                    if [ $? -eq 0 ]; then
                        print_info "Successfully unmounted '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script."
                    else
                        log_error "Failed to unmount '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' via script. Manual unmount may be required."
                    fi
                else
                    print_info "Mount point '$EXPANDED_LOCAL_MOUNT_POINT_CLEANUP' is not currently mounted. No unmount needed by script."
                fi
            else
                print_error "LOCAL_MOUNT_POINT is not set. Cannot attempt conditional unmount."
            fi
        else
            log_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable. Cannot unmount automatically."
        fi
    fi

    print_info "Cleanup routine finished."
}

# Set trap for cleanup on EXIT or signals
trap cleanup EXIT INT TERM HUP

# * Usage Function
usage() {
    cat << EOF
Usage: $0 [options]

Retrieves completed transcript files from the Stentor droplet to local storage.

Features:
  - Copies completed transcripts from droplet's completed/ directory to local directory
  - Uses retrieval archive (retrieval_archive.txt) to prevent re-copying files
  - Automatically mounts the remote directory if not already mounted
  - Automatically unmounts after completion ONLY if mounted by this script
  - Allows override of destination directory via command-line argument
  - Destination directory must already exist (will not be created automatically)

Options:
  -d, --destination DIR  Override LOCAL_TRANSCRIPT_DIR from config
                         Directory must already exist (script will not create it)
  -n, --dry-run         Show what would be retrieved without copying
  -v, --verbose         Enable verbose output during retrieval
  -h, --help            Display this help message and exit

Configuration:
  The script reads configuration from stentor.conf in this order:
    1. $PROJECT_ENV_FILE
    2. $HOME_ENV_FILE

  Required variables in stentor.conf:
    - LOCAL_MOUNT_POINT: Where the droplet filesystem is mounted
    - LOCAL_TRANSCRIPT_DIR: Where to store retrieved transcripts

Dependencies:
  - mount_droplet_yt.sh:  (In script directory) Required for automatic mounting
  - unmount_droplet_yt.sh:(In script directory) Required for automatic unmounting
  - sshfs:                Required by the mount/unmount scripts

Examples:
  # Retrieve using config defaults
  $0

  # Dry run to preview what would be retrieved
  $0 --dry-run

  # Retrieve to custom location (must exist)
  mkdir -p ~/Desktop/transcripts
  $0 -d ~/Desktop/transcripts

  # Verbose mode for detailed progress
  $0 -v

Exit Codes:
  0: Success
  1: Missing dependencies, config, or destination validation error
  4: Mount failure
EOF
    exit 1
}

# * Argument Parsing
parse_arguments() {
    DESTINATION_OVERRIDE=""
    DRY_RUN=false
    VERBOSE=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -d|--destination)
                if [ -n "$2" ]; then
                    DESTINATION_OVERRIDE="$2"
                    shift
                else
                    print_error "--destination option requires a directory path."
                    usage
                fi
                ;;
            -n|--dry-run)
                DRY_RUN=true
                ;;
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

# * Main Script Logic
main() {
    parse_arguments "$@"

    print_step "Starting: Retrieve Completed Transcripts from Stentor Droplet"

    # 1. Dependency checks
    print_info "Performing dependency checks..."

    if [ ! -x "$MOUNT_SCRIPT" ]; then
        print_error "Mount script not found or not executable: $MOUNT_SCRIPT"
        exit 1
    fi
    print_info "Mount script '$MOUNT_SCRIPT' found."

    if [ ! -x "$UNMOUNT_SCRIPT" ]; then
        print_error "Unmount script not found or not executable: $UNMOUNT_SCRIPT"
        exit 1
    fi
    print_info "Unmount script '$UNMOUNT_SCRIPT' found."
    print_info "Dependency checks passed."

    # 2. Load stentor.conf configuration
    print_info "Attempting to load stentor.conf configuration..."
    CONFIG_SOURCED=false
    if [ -f "$PROJECT_ENV_FILE" ]; then
        print_info "Found project stentor.conf file: $PROJECT_ENV_FILE. Sourcing..."
        # shellcheck source=./stentor.conf
        source "$PROJECT_ENV_FILE"
        CONFIG_SOURCED=true
        print_info "Loaded configuration from $PROJECT_ENV_FILE"
    elif [ -f "$HOME_ENV_FILE" ]; then
        print_info "Found home stentor.conf file: $HOME_ENV_FILE. Sourcing..."
        # shellcheck source=~/.stentor/stentor.conf
        source "$HOME_ENV_FILE"
        CONFIG_SOURCED=true
        print_info "Loaded configuration from $HOME_ENV_FILE"
    else
        print_error "No stentor.conf file found at $PROJECT_ENV_FILE or $HOME_ENV_FILE."
        print_error "Please create a configuration file with LOCAL_MOUNT_POINT and LOCAL_TRANSCRIPT_DIR."
        exit 1
    fi

    # 3. Validate required configuration variables
    if [ -z "${LOCAL_MOUNT_POINT:-}" ]; then
        print_error "Required variable 'LOCAL_MOUNT_POINT' is not set in stentor.conf."
        exit 1
    fi
    print_info "LOCAL_MOUNT_POINT: '$LOCAL_MOUNT_POINT'"

    if [ -z "${LOCAL_TRANSCRIPT_DIR:-}" ] && [ -z "$DESTINATION_OVERRIDE" ]; then
        print_error "Required variable 'LOCAL_TRANSCRIPT_DIR' is not set in stentor.conf and no destination override provided."
        exit 1
    fi

    # 4. Determine Final Destination Directory
    print_info "Determining final destination directory..."
    if [ -n "$DESTINATION_OVERRIDE" ]; then
        eval FINAL_DESTINATION_DIR="$DESTINATION_OVERRIDE"
        print_info "Using destination override: $FINAL_DESTINATION_DIR"
    else
        eval FINAL_DESTINATION_DIR="$LOCAL_TRANSCRIPT_DIR"
        print_info "Using LOCAL_TRANSCRIPT_DIR from stentor.conf: $FINAL_DESTINATION_DIR"
    fi

    # 5. Validate destination directory exists
    if [ ! -d "$FINAL_DESTINATION_DIR" ]; then
        print_error "Destination directory does not exist: $FINAL_DESTINATION_DIR"
        print_error "Please create the directory first: mkdir -p \"$FINAL_DESTINATION_DIR\""
        exit 1
    fi
    print_info "Destination directory verified: '$FINAL_DESTINATION_DIR'"

    # 6. Mount Management
    SCRIPT_PERFORMED_MOUNT=false
    eval EXPANDED_LOCAL_MOUNT_POINT="$LOCAL_MOUNT_POINT"

    print_info "Checking mount status for '$EXPANDED_LOCAL_MOUNT_POINT'..."

    if _is_mount_verified_and_responsive "$EXPANDED_LOCAL_MOUNT_POINT"; then
        print_info "Mount '$EXPANDED_LOCAL_MOUNT_POINT' is already active and responsive."
    else
        print_info "Mount '$EXPANDED_LOCAL_MOUNT_POINT' not verified or not responsive. Attempting to mount..."

        # Attempt to unmount first, in case of a stale mount
        if mount | grep -q " on $EXPANDED_LOCAL_MOUNT_POINT "; then
            print_info "Attempting to unmount potentially stale mount at '$EXPANDED_LOCAL_MOUNT_POINT'..."
            if [ -x "$UNMOUNT_SCRIPT" ]; then
                "$UNMOUNT_SCRIPT"
                sleep 2
            else
                print_error "Unmount script '$UNMOUNT_SCRIPT' not found or not executable."
            fi
        fi

        print_info "Attempting to mount '$EXPANDED_LOCAL_MOUNT_POINT' via $MOUNT_SCRIPT..."
        if [ -x "$MOUNT_SCRIPT" ]; then
            "$MOUNT_SCRIPT"
            if [ $? -eq 0 ]; then
                print_info "Mount script executed successfully. Waiting 2 seconds for mount to stabilize..."
                sleep 2
                print_info "Verifying mount..."
                if _is_mount_verified_and_responsive "$EXPANDED_LOCAL_MOUNT_POINT"; then
                    print_info "Successfully mounted and verified '$EXPANDED_LOCAL_MOUNT_POINT'."
                    SCRIPT_PERFORMED_MOUNT=true
                else
                    print_error "Failed: Mount verification failed for $EXPANDED_LOCAL_MOUNT_POINT after mount attempt"
                    exit 4
                fi
            else
                print_error "Failed: Mount script $MOUNT_SCRIPT execution error"
                exit 4
            fi
        else
            print_error "Failed: Mount script $MOUNT_SCRIPT not found/executable"
            exit 1
        fi
    fi

    # 7. Determine source directory (completed/ in the mounted filesystem)
    SOURCE_COMPLETED_DIR="${EXPANDED_LOCAL_MOUNT_POINT}/completed"
    print_info "Source completed directory: $SOURCE_COMPLETED_DIR"

    if [ ! -d "$SOURCE_COMPLETED_DIR" ]; then
        print_error "Source completed directory does not exist: $SOURCE_COMPLETED_DIR"
        print_error "Check that the remote filesystem structure is correct."
        exit 1
    fi

    # Test if source directory is actually accessible (catches stale mounts)
    print_info "Testing accessibility of source directory..."
    if ! ls -A "$SOURCE_COMPLETED_DIR" >/dev/null 2>&1; then
        print_error "Source directory exists but is not accessible (possibly stale mount)"
        print_error "Try unmounting and remounting: $UNMOUNT_SCRIPT && $MOUNT_SCRIPT"
        exit 4
    fi
    print_info "Source directory is accessible."

    # 8. Setup destination completed/ subdirectory and archive file
    DEST_COMPLETED_DIR="${FINAL_DESTINATION_DIR}/completed"
    ARCHIVE_FILE="${FINAL_DESTINATION_DIR}/retrieval_archive.txt"
    OPERATION_LOG="${FINAL_DESTINATION_DIR}/retrieval_log.txt"

    print_info "Ensuring destination completed/ subdirectory exists..."
    if [ ! -d "$DEST_COMPLETED_DIR" ]; then
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$DEST_COMPLETED_DIR"
            if [ $? -ne 0 ]; then
                print_error "Failed to create destination completed directory: $DEST_COMPLETED_DIR"
                exit 1
            fi
            print_info "Created destination completed directory: $DEST_COMPLETED_DIR"
        else
            print_info "[DRY RUN] Would create destination completed directory: $DEST_COMPLETED_DIR"
        fi
    fi

    # Create archive file if it doesn't exist
    if [ ! -f "$ARCHIVE_FILE" ]; then
        if [ "$DRY_RUN" = false ]; then
            touch "$ARCHIVE_FILE"
            print_info "Created retrieval archive file: $ARCHIVE_FILE"
        else
            print_info "[DRY RUN] Would create retrieval archive file: $ARCHIVE_FILE"
        fi
    fi

    # 9. Retrieve files from completed directory
    print_step "Retrieving transcript files..."

    FILES_TO_RETRIEVE=()
    FILES_SKIPPED=0
    FILES_COPIED=0
    TOTAL_SIZE=0
    TOTAL_FILES_FOUND=0

    # Build list of files to retrieve
    print_info "Scanning source directory for files..."
    shopt -s nullglob # Prevent * from being literal if no files match
    for file in "${SOURCE_COMPLETED_DIR}/"*; do
        if [ -f "$file" ]; then
            TOTAL_FILES_FOUND=$((TOTAL_FILES_FOUND + 1))
            filename=$(basename "$file")

            # Check if already retrieved
            if [ -f "$ARCHIVE_FILE" ] && grep -Fxq "$filename" "$ARCHIVE_FILE"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                if [ "$VERBOSE" = true ]; then
                    print_info "Skipping (already retrieved): $filename"
                fi
            else
                FILES_TO_RETRIEVE+=("$file")
                if [ "$VERBOSE" = true ]; then
                    print_info "Found new file: $filename"
                fi
            fi
        fi
    done
    shopt -u nullglob

    # Report scan results
    print_info "Scan complete: Found $TOTAL_FILES_FOUND total file(s) in source directory"
    print_info "Files already retrieved (in archive): $FILES_SKIPPED"
    print_info "New files to retrieve: ${#FILES_TO_RETRIEVE[@]}"

    # Report what will be done
    if [ ${#FILES_TO_RETRIEVE[@]} -eq 0 ]; then
        if [ "$TOTAL_FILES_FOUND" -eq 0 ]; then
            print_info "No files found in source directory. Nothing to retrieve."
            print_info "Source directory may be empty or you may need to wait for transcription to complete."
        else
            print_info "No new files to retrieve. All $TOTAL_FILES_FOUND file(s) already in archive."
        fi
    else
        print_info "Found ${#FILES_TO_RETRIEVE[@]} new file(s) to retrieve."
        print_info "Files skipped (already retrieved): $FILES_SKIPPED"

        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY RUN] Would retrieve the following files:"
            for file in "${FILES_TO_RETRIEVE[@]}"; do
                filename=$(basename "$file")
                filesize=$(du -h "$file" | cut -f1)
                print_info "  - $filename ($filesize)"
            done
        else
            # Copy files
            for file in "${FILES_TO_RETRIEVE[@]}"; do
                filename=$(basename "$file")
                filesize_bytes=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
                TOTAL_SIZE=$((TOTAL_SIZE + filesize_bytes))

                if [ "$VERBOSE" = true ]; then
                    filesize_human=$(du -h "$file" | cut -f1)
                    print_info "Copying: $filename ($filesize_human)"
                fi

                # Copy the file (preserving timestamps)
                cp -p "$file" "$DEST_COMPLETED_DIR/"
                if [ $? -eq 0 ]; then
                    # Record in archive
                    echo "$filename" >> "$ARCHIVE_FILE"
                    FILES_COPIED=$((FILES_COPIED + 1))
                else
                    log_error "Failed to copy: $filename"
                fi
            done

            # Calculate human-readable total size
            if [ "$TOTAL_SIZE" -gt 1073741824 ]; then
                TOTAL_SIZE_HUMAN=$(awk "BEGIN {printf \"%.2f GB\", $TOTAL_SIZE/1073741824}")
            elif [ "$TOTAL_SIZE" -gt 1048576 ]; then
                TOTAL_SIZE_HUMAN=$(awk "BEGIN {printf \"%.2f MB\", $TOTAL_SIZE/1048576}")
            elif [ "$TOTAL_SIZE" -gt 1024 ]; then
                TOTAL_SIZE_HUMAN=$(awk "BEGIN {printf \"%.2f KB\", $TOTAL_SIZE/1024}")
            else
                TOTAL_SIZE_HUMAN="${TOTAL_SIZE} bytes"
            fi

            # Log operation to operation log
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$TIMESTAMP | Retrieved $FILES_COPIED files ($TOTAL_SIZE_HUMAN) | Status: SUCCESS" >> "$OPERATION_LOG"

            print_success "Successfully retrieved $FILES_COPIED file(s) totaling $TOTAL_SIZE_HUMAN"
            print_info "Files saved to: $DEST_COMPLETED_DIR"
            print_info "Archive updated: $ARCHIVE_FILE"
        fi
    fi

    print_step "Retrieval operation complete"
}

# Run main function with all script arguments
main "$@"
