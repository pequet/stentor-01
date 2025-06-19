#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Audio Processing & Transcription System
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Server-side queue processor for Stentor audio transcription.
#   Monitors inbox for audio files and processes them using process_audio.sh
#   with proper locking, file organization, and anti-reprocessing logic.
#
# Features:
#   - Robust locking with failsafe cleanup
#   - Processes oldest files first
#   - Handles success/failure with appropriate file organization
#   - Prevents reprocessing of already-handled files
#   - Comprehensive logging and error handling
#
# Usage:
#   ./queue_processor.sh [OPTIONS]
#
# Options:
#   --aggressive-cleanup      Meta-flag to enable all cleanup options below.
#   --cleanup-wav-files       On success, deletes temporary WAV files from the run directory
#                             in 'stentor_processing_runs' (workable WAV and segments).
#   --cleanup-run-logs        On success, deletes the entire specific run directory from
#                             'stentor_processing_runs', including all logs and transcripts.
#   --cleanup-original-audio  On success, deletes the original source audio file
#                             from the 'stentor_harvesting/completed' directory.
#   --models "list"           Optional. Comma-separated list of Whisper models (e.g.,
#                             "tiny.en,base.en") to be passed to process_audio.sh.
#                             If not provided, process_audio.sh uses its default.
#   --timeout-multiplier N    Optional. An integer to multiply segment duration by for
#                             dynamic timeout calculation in process_audio.sh.
#                             If not provided, process_audio.sh uses its default.
#   -h, --help                Show this help message and exit.
#
# Dependencies:
#   - process_audio.sh: The main audio processing script.
#   - Standard Unix utilities: date, cat, stat, kill, rm, mkdir, touch, md5sum/md5, grep, awk, wc, tail.
#
# Cron Example:
#   Typically run via cron (logs to its own log file):
#   */5 * * * * /path/to/scripts/audio-processing/queue_processor.sh --aggressive-cleanup
#   # To use specific models via cron (example with a more resilient sequence):
#   # */5 * * * * /path/to/scripts/audio-processing/queue_processor.sh --aggressive-cleanup --models "medium.en-q5_0,small.en-q5_1,base.en-q5_1"
#   # */5 * * * * /path/to/scripts/audio-processing/queue_processor.sh --cleanup-wav-files --cleanup-original-audio --models "medium.en-q5_0,small.en-q5_1,base.en-q5_1" --timeout-multiplier 20
#
# Changelog:
#   1.0.0 - 2025-05-25 - Initial release with robust locking, anti-reprocessing, and logging.
#   1.0.1 - 2025-06-05 - Added --models and --timeout-multiplier options.
#   1.0.2 - 2025-06-05 - Require params, show help by default. Handle exit code 10 from child script to retry locked files.
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

# * Source Utilities
source "$(dirname "$0")/../utils/messaging_utils.sh"

# * Global Variables and Configuration

# ** Lock File Configuration
LOCK_FILE="$HOME/.stentor/queue_processor.lock"
LOCK_TIMEOUT=7200  # 2 hours in seconds
LOG_FILE="$HOME/.stentor/logs/queue_processor.log"
LOCK_ACQUIRED_BY_THIS_PROCESS=false # Flag to track if this instance acquired the lock

# Processing directories
PROCESSING_BASE_DIR="$HOME/stentor_harvesting"
INBOX_DIR="$PROCESSING_BASE_DIR/inbox"
PROCESSING_DIR="$PROCESSING_BASE_DIR/processing"
COMPLETED_DIR="$PROCESSING_BASE_DIR/completed"
FAILED_DIR="$PROCESSING_BASE_DIR/failed"
LOGS_DIR="$PROCESSING_BASE_DIR/logs"

# History file for anti-reprocessing
PROCESSED_HISTORY_FILE="$PROCESSING_BASE_DIR/processed_files.txt"

# Path to process_audio.sh script
PROCESS_AUDIO_SCRIPT="$(dirname "$0")/process_audio.sh"

# Supported audio file extensions
AUDIO_EXTENSIONS=("mp3" "wav" "m4a" "flac" "ogg" "aac")

CHILD_PID="" # Initialize CHILD_PID to manage the process_audio.sh script

# * Logging Functions (Local to queue_processor.sh)
_log_message_local() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Keep [QUEUE_PROCESSOR] specific to this script
    local log_entry="[$timestamp] [QUEUE_PROCESSOR] [$level] $message"
    
    # Always print to stdout
    printf -- "%s\n" "$log_entry"
    
    # Also write to the script-specific LOG_FILE
    if [ -n "${LOG_FILE:-}" ]; then # Check if LOG_FILE is set and not empty
        if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
            printf -- "[%s] [QUEUE_PROCESSOR] [ERROR] Cannot create log directory: %s for local log file\n" "$timestamp" "$(dirname "$LOG_FILE")" >&2
        fi
        if ! printf -- "%s\n" "$log_entry" >> "$LOG_FILE" 2>/dev/null; then
            printf -- "[%s] [QUEUE_PROCESSOR] [ERROR] Cannot write to local LOG_FILE: %s\n" "$timestamp" "$LOG_FILE" >&2
        fi
    fi
}

log_info_local() { _log_message_local "INFO" "$1"; }
log_warn_local() { _log_message_local "WARN" "$1"; }
log_error_local() {
    _log_message_local "ERROR" "$1"
    printf "ERROR: %s\n" "$1" >&2 # Direct to stderr
}
# Retain a simple 'log_local' for brevity, mapping to info.
log_local() { log_info_local "$1"; }

# * Display Help Function
display_help() {
    # Extracts the "Usage" and "Options" sections from the script's own comments.
    echo ""
    # Use sed to find the start of the Usage block and print until an empty comment line.
    sed -n '/^# Usage:/,/^#\s*$/ s/^#\s*//p' "$0"
    echo ""
    # Use sed to find the start of the Options block and print until an empty comment line.
    sed -n '/^# Options:/,/^#\s*$/ s/^#\s*//p' "$0"
    echo ""
}

# * Lock Management Functions
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
            log_warn_local "Another queue processor instance is running (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
            echo "--- DEBUG LOCK END (PID RUNNING) ---" >&2
            return 1
        else
            echo "DEBUG BRANCH TAKEN: PID $lock_pid IS considered NOT RUNNING (or PID was empty)." >&2
            if [[ "$lock_file_age_seconds" -ne -1 ]]; then # Age was successfully calculated
                echo "DEBUG: Comparing age: $lock_file_age_seconds > $LOCK_TIMEOUT ?" >&2
                if [[ "$lock_file_age_seconds" -gt "$LOCK_TIMEOUT" ]]; then
                    echo "DEBUG: AGE COMPARISON TRUE. Lock IS STALE." >&2
                    log_info_local "Removing stale lock file (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
                    rm -f "$LOCK_FILE"
                else
                    echo "DEBUG: AGE COMPARISON FALSE. Lock IS NOT STALE ENOUGH." >&2
                    log_warn_local "Lock file (PID: $lock_pid) exists but is not older than timeout. Details: $lock_file_age_info. Not removing. Lock file: $LOCK_FILE"
                    echo "--- DEBUG LOCK END (PID NOT RUNNING, NOT STALE ENOUGH) ---" >&2
                    return 1
                fi
            else # Age could not be determined earlier
                echo "DEBUG: Age could not be calculated. Assuming stale and removing." >&2
                log_warn_local "Could not determine age of lock file (PID: $lock_pid). Details: $lock_file_age_info. Assuming stale and removing. Lock file: $LOCK_FILE"
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
        echo "DEBUG: release_lock called by owning process. Removing $LOCK_FILE" >&2
        rm -f "$LOCK_FILE"
    else
        echo "DEBUG: release_lock called, but lock not owned by this process. Lock not removed." >&2
    fi
}

# * Directory Setup
setup_directories() {
    log_local "Setting up processing directories..."
    
    # Create .stentor logs directory first
    mkdir -p "$HOME/.stentor/logs"
    
    for dir in "$PROCESSING_BASE_DIR" "$INBOX_DIR" "$PROCESSING_DIR" "$COMPLETED_DIR" "$FAILED_DIR" "$LOGS_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            if [ $? -ne 0 ]; then
                log_error_local "Failed to create directory: $dir"
                exit 1
            fi
            log_local "Created directory: $dir"
        fi
    done
    
    # Create processed history file if it doesn't exist
    if [ ! -f "$PROCESSED_HISTORY_FILE" ]; then
        touch "$PROCESSED_HISTORY_FILE"
        log_local "Created processed history file: $PROCESSED_HISTORY_FILE"
    fi
}

# * File Hash Function
get_file_hash() {
    local file_path="$1"
    local hash=""
    
    log_local "DEBUG_HASH: get_file_hash received file_path: '$file_path'"
    
    if command -v md5sum &> /dev/null; then
        log_local "DEBUG_HASH: About to run: md5sum '$file_path' | awk '{print $1}'"
        hash=$(md5sum "$file_path" | awk '{print $1}')
    elif command -v md5 &> /dev/null; then
        log_local "DEBUG_HASH: About to run: md5 -q '$file_path'"
        hash=$(md5 -q "$file_path")
    else
        log_error_local "Neither md5sum nor md5 command available"
        return 1
    fi
    
    echo "$hash"
}

# * Anti-Reprocessing Check
is_already_processed() {
    local file_path="$1"
    local file_hash
    
    log_local "DEBUG_HASH: is_already_processed received file_path: '$file_path'"
    file_hash=$(get_file_hash "$file_path")
    if [ $? -ne 0 ]; then
        log_error_local "Failed to calculate hash for $file_path"
        return 1
    fi
    
    if grep -q "^$file_hash" "$PROCESSED_HISTORY_FILE" 2>/dev/null; then
        return 0  # Already processed
    else
        return 1  # Not processed
    fi
}

# * Mark File as Processed
mark_as_processed() {
    local file_path="$1"
    local status="$2"  # "SUCCESS" or "FAILED"
    local file_hash
    
    log_local "DEBUG_HASH: mark_as_processed received file_path: '$file_path' (status: $status)"
    file_hash=$(get_file_hash "$file_path")
    if [ $? -ne 0 ]; then
        log_error_local "Failed to calculate hash for marking: $file_path"
        return 1
    fi
    
    local timestamp=$(date +%Y-%m-%d_%H%M%S)
    local basename=$(basename "$file_path")
    
    echo "$file_hash|$timestamp|$status|$basename" >> "$PROCESSED_HISTORY_FILE"
    log_local "Marked file as processed: $basename ($status)"
}

# * Find Audio Files
find_audio_files() {
    local search_dir="$1"
    local temp_file=$(mktemp)
    
    # Find all audio files and get their modification times
    for ext in "${AUDIO_EXTENSIONS[@]}"; do
        # Exclude macOS resource fork files (._*) and other hidden files
        find "$search_dir" -maxdepth 1 -name "*.${ext}" -type f ! -name "._*" ! -name ".DS_Store" -print0 2>/dev/null | \
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                # Get modification time and filename, separated by tab
                stat -c "%Y\t%n" "$file" 2>/dev/null || stat -f "%m\t%N" "$file" 2>/dev/null
            fi
        done >> "$temp_file"
        
        # Also check uppercase extensions, excluding hidden files
        local ext_upper=$(echo "$ext" | tr '[:lower:]' '[:upper:]')
        find "$search_dir" -maxdepth 1 -name "*.${ext_upper}" -type f ! -name "._*" ! -name ".DS_Store" -print0 2>/dev/null | \
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                # Get modification time and filename, separated by tab
                stat -c "%Y\t%n" "$file" 2>/dev/null || stat -f "%m\t%N" "$file" 2>/dev/null
            fi
        done >> "$temp_file"
    done
    
    # Sort by modification time (oldest first) and output just the filenames
    if [ -s "$temp_file" ]; then
        sort -n "$temp_file" | cut -f2- -d $'\t'
    fi
    
    # Clean up temp file
    rm -f "$temp_file"
}

# * Process Single File
process_file() {
    local file_path="$1"
    local basename=$(basename "$file_path")
    local base_name_no_ext="${basename%.*}"  # Remove extension to get base name
    local timestamp=$(date +%Y-%m-%d_%H%M%S)
    local log_file="$LOGS_DIR/${timestamp}_${basename}.log"
    
    log_local "Processing file: $basename"
    
    # Move all files with same base name to processing directory
    for related_file in "$INBOX_DIR/${base_name_no_ext}."*; do
        if [ -f "$related_file" ]; then
            local related_basename=$(basename "$related_file")
            mv "$related_file" "$PROCESSING_DIR/$related_basename"
            log_local "Moved related file: $related_basename"
        fi
    done
    
    local processing_file="$PROCESSING_DIR/$basename"
    if [ ! -f "$processing_file" ]; then
        log_error_local "Failed to move primary file to processing directory: $basename"
        # Attempt to move files back to inbox if primary file move failed.
        for related_file in "$PROCESSING_DIR/${base_name_no_ext}."*; do
            if [ -f "$related_file" ]; then
                local related_basename=$(basename "$related_file")
                mv "$related_file" "$INBOX_DIR/$related_basename"
                log_warn_local "Moved back to inbox: $related_basename due to primary file move failure"
            fi
        done
        return 1
    fi
    
    # Run process_audio.sh and capture output
    local process_output
    local process_exit_code
    
    # Build the command for process_audio.sh
    local process_audio_cmd_array=("$PROCESS_AUDIO_SCRIPT")

    # Add --cleanup-temp-audio if cleanup of WAVs is enabled
    if [ "${CLEANUP_WAV:-false}" = "true" ]; then
        process_audio_cmd_array+=("--cleanup-temp-audio")
    fi
    
    # Add the processing file path
    process_audio_cmd_array+=("$processing_file")
    
    # Conditionally add user-specified models and timeout multiplier
    # process_audio.sh expects: <input_audio_file_path> [whisper_model_list] [timeout_duration_multiplier]
    # The --cleanup-temp-audio flag is handled by process_audio.sh's own parsing.

    if [ -n "$USER_SPECIFIED_MODELS" ]; then
        process_audio_cmd_array+=("$USER_SPECIFIED_MODELS")
        # If models are specified, and multiplier is also specified, add multiplier next
        if [ -n "$USER_SPECIFIED_TIMEOUT_MULTIPLIER" ]; then
            process_audio_cmd_array+=("$USER_SPECIFIED_TIMEOUT_MULTIPLIER")
        fi
    elif [ -n "$USER_SPECIFIED_TIMEOUT_MULTIPLIER" ]; then
        # Models are NOT specified, but multiplier IS.
        # We need to pass an empty string or default for models first,
        # then the multiplier, so process_audio.sh interprets them correctly.
        # process_audio.sh uses DEFAULT_WHISPER_MODEL_LIST if the model string is empty or not provided.
        process_audio_cmd_array+=("") # Empty string for models, process_audio.sh will use its default
        process_audio_cmd_array+=("$USER_SPECIFIED_TIMEOUT_MULTIPLIER")
    fi
    
    log_local "Executing process_audio.sh for: $basename"
    log_local "COMMAND (to be backgrounded): ${process_audio_cmd_array[*]}"

    # Prepare a temporary file for process_audio.sh output
    local temp_process_output_file
    temp_process_output_file=$(mktemp "$PROCESSING_DIR/${basename}.out.XXXXXX")

    # Run process_audio.sh.
    # Use stdbuf to encourage line-buffering from process_audio.sh.
    # Its stdout (transcript path) and stderr (logs) will be combined (2>&1).
    # This combined stream is piped to tee.
    # tee writes it to temp_process_output_file AND to queue_processor.sh's stderr for real-time display.
    # The entire pipeline is backgrounded.
    (stdbuf -oL -eL "${process_audio_cmd_array[@]}" 2>&1 | tee "$temp_process_output_file" >&2) &
    CHILD_PID=$! # Capture child PID
    log_local "process_audio.sh started with PID $CHILD_PID. Output being teed to $temp_process_output_file and terminal (stderr)."

    # Wait for the child to finish
    wait "$CHILD_PID"
    process_exit_code=$?
    CHILD_PID="" # Clear CHILD_PID after normal completion or caught error

    process_output=$(cat "$temp_process_output_file")
    # The output was already sent to terminal (stderr) by the backgrounded tee.
    # Now, just append the captured process_output to the main queue_processor log file ($LOG_FILE).
    if [ -n "$process_output" ]; then # Ensure process_output is not empty before printing
        printf "%s\\n" "$process_output" >> "$LOG_FILE"
    fi
    rm -f "$temp_process_output_file"
    
    log_local "process_audio.sh (PID formerly $CHILD_PID) completed with exit code: $process_exit_code"

    # Log the processing output details to its specific log file
    {
        echo "=== Processing Log for $basename ==="
        echo "Timestamp: $timestamp"
        # Reconstruct command for logging (without env var export shown as part of command)
        echo "Command: ${process_audio_cmd_array[*]}"
        echo "Exit Code: $process_exit_code"
        echo "=== Process Output ==="
        echo "$process_output"
        echo "=== End of Log ==="
    } > "$log_file"
    
    # Handle success/failure - move all related files
    if [ $process_exit_code -eq 0 ]; then
        # Success - move all related files to completed directory
        for related_file in "$PROCESSING_DIR/${base_name_no_ext}."*; do
            if [ -f "$related_file" ]; then
                local related_basename=$(basename "$related_file")
                mv "$related_file" "$COMPLETED_DIR/$related_basename"
                log_local "Moved to completed: $related_basename"
            fi
        done
        
        # Extract transcript path from output (last line should be the path)
        local transcript_path_from_process_audio
        transcript_path_from_process_audio=$(echo "$process_output" | tail -n 1)
        
        log_local "Successfully processed: $basename"
        log_local "Transcript from process_audio.sh at: $transcript_path_from_process_audio"
        
        # Copy transcript to completed folder with matching name
        if [ -f "$transcript_path_from_process_audio" ]; then
            local completed_transcript_in_queue_dir="$COMPLETED_DIR/${base_name_no_ext}.txt"
            
            if cp "$transcript_path_from_process_audio" "$completed_transcript_in_queue_dir"; then
                log_local "Transcript copied to queue's completed folder: ${completed_transcript_in_queue_dir}"
            else
                log_warn_local "Failed to copy transcript to queue's completed folder: $completed_transcript_in_queue_dir"
            fi

            # If cleanup of run logs is enabled, remove process_audio.sh's run directory
            if [ "${CLEANUP_LOGS:-false}" = "true" ]; then
                # Derive the run directory path from the transcript path
                # Assumes transcript_path_from_process_audio is like /path/to/stentor_processing_runs/hash_timestamp/audio_transcript.txt
                local process_audio_run_dir
                process_audio_run_dir=$(dirname "$transcript_path_from_process_audio")
                if [ -d "$process_audio_run_dir" ] && [[ "$process_audio_run_dir" == *"stentor_processing_runs"* ]]; then # Basic sanity check
                    log_local "Cleanup: Removing process_audio.sh run directory: $process_audio_run_dir"
                    rm -rf "$process_audio_run_dir"
                else
                    log_warn_local "Cleanup: Could not reliably determine or validate process_audio.sh run directory from transcript path: $transcript_path_from_process_audio. Directory not removed."
                fi
            fi
        else
            log_warn_local "Transcript file from process_audio.sh not found at: $transcript_path_from_process_audio. Cannot copy or perform aggressive cleanup of its run directory."
        fi
        
        local completed_file="$COMPLETED_DIR/$basename"
        mark_as_processed "$completed_file" "SUCCESS"

        # If cleanup of original audio is enabled, delete it from the completed directory
        # This is the final step after a successful transcription and logging.
        if [ "${CLEANUP_ORIGINAL:-false}" = "true" ]; then
            if [ -f "$completed_file" ]; then
                log_local "Cleanup: Deleting original processed audio file from completed directory: $completed_file"
                rm -f "$completed_file"
            else
                log_warn_local "Cleanup: Could not find original audio file in completed directory to delete: $completed_file"
            fi
        fi

        return 0
    elif [ $process_exit_code -eq 10 ]; then
        # Locked/Retry - move all related files back to inbox
        log_warn_local "process_audio.sh was locked (exit code: 10). Moving files for $basename back to inbox for retry."
        for related_file in "$PROCESSING_DIR/${base_name_no_ext}."*; do
            if [ -f "$related_file" ]; then
                local related_basename=$(basename "$related_file")
                mv "$related_file" "$INBOX_DIR/$related_basename"
                log_local "Moved back to inbox for retry: $related_basename"
            fi
        done
        # This is not a "failure" of the queue, so return a special code or handle as success for the queue's perspective
        return 10 # Propagate special exit code for logging if needed, or just return 0
    else
        # Failure - move all related files to failed directory
        for related_file in "$PROCESSING_DIR/${base_name_no_ext}."*; do
            if [ -f "$related_file" ]; then
                local related_basename=$(basename "$related_file")
                mv "$related_file" "$FAILED_DIR/$related_basename"
                log_local "Moved to failed: $related_basename"
            fi
        done
        
        log_error_local "Failed to process: $basename (exit code: $process_exit_code)"
        log_error_local "Error output: $process_output"
        
        local failed_file="$FAILED_DIR/$basename"
        mark_as_processed "$failed_file" "FAILED"
        return 1
    fi
}

# Cleanup function for queue_processor.sh
cleanup_queue_processor_and_child() {
    log_local "Queue processor cleanup initiated (Signal: $?)..."

    if [ -n "$CHILD_PID" ]; then
        # Check if the process actually exists
        if ps -p "$CHILD_PID" > /dev/null; then
            log_local "Attempting to terminate child process $CHILD_PID (process_audio.sh) with SIGTERM..."
            kill -TERM "$CHILD_PID" # Send SIGTERM to the child
            
            # Give the child a moment to clean up - increased to 60 seconds
            local wait_time=60 # Increased waoit time to let the child process finish
            local counter=0
            while ps -p "$CHILD_PID" > /dev/null && [ "$counter" -lt "$wait_time" ]; do
                sleep 1
                counter=$((counter + 1))
                log_local "Waiting for child $CHILD_PID to terminate... ($counter/$wait_time)"
            done

            if ps -p "$CHILD_PID" > /dev/null; then
                log_warn_local "Child process $CHILD_PID did not terminate gracefully after $wait_time seconds. Sending SIGKILL."
                kill -KILL "$CHILD_PID"
                
                # Safeguard: If we SIGKILLed it, and the process_audio.lock matches this CHILD_PID, remove it.
                local process_audio_lock_file="$HOME/.stentor/process_audio.lock"
                if [ -f "$process_audio_lock_file" ]; then
                    local locked_pid
                    locked_pid=$(cat "$process_audio_lock_file" 2>/dev/null)
                    if [ "$locked_pid" = "$CHILD_PID" ]; then
                        log_warn_local "Forcefully removed $process_audio_lock_file because child $CHILD_PID (which owned it) was SIGKILLed."
                        rm -f "$process_audio_lock_file"
                    else
                        log_local "Child $CHILD_PID was SIGKILLed, but $process_audio_lock_file PID ($locked_pid) does not match. Lock not removed by parent."
                    fi
                fi
            else
                log_local "Child process $CHILD_PID terminated gracefully."
            fi
        else
            log_local "Child process $CHILD_PID no longer exists or was not started when cleanup initiated."
        fi
    fi
    CHILD_PID="" # Ensure it's cleared

    # Release queue_processor's own lock
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        log_local "Releasing queue_processor.sh lock ($LOCK_FILE)."
        rm -f "$LOCK_FILE"
        # LOCK_ACQUIRED_BY_THIS_PROCESS=false # Not strictly needed as script is exiting
    else
        log_local "Queue_processor.sh lock ($LOCK_FILE) not acquired by this instance or already considered released."
    fi
    log_local "Queue processor cleanup finished."
    # Standard exit trap will also call this, so ensure it's idempotent or careful.
    # If script exits due to 'set -e', $? will be the error code.
    # If due to signal, $? might be 128 + signal number.
    # We might want to exit with the caught signal's exit code if applicable.
}

# * Main Processing Loop
main() {
    # If no arguments are provided, display help and exit.
    if [ $# -eq 0 ]; then
        display_help
        exit 0
    fi

    # Set up trap to ensure lock is released and child is handled on exit/signal
    # The trap is now more comprehensive
    trap 'cleanup_queue_processor_and_child' EXIT INT TERM HUP QUIT
    
    display_status_message " " "Starting: Queue Processor"
    log_local "Command: $0 $*"
    
    # Parse command line arguments
    CLEANUP_WAV=false
    CLEANUP_LOGS=false
    CLEANUP_ORIGINAL=false
    USER_SPECIFIED_MODELS="" # Initialize
    USER_SPECIFIED_TIMEOUT_MULTIPLIER="" # Initialize

    # Use a while loop for more robust argument parsing
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            -h|--help)
                display_help
                exit 0
                ;;
            --aggressive-cleanup)
                CLEANUP_WAV=true
                CLEANUP_LOGS=true
                CLEANUP_ORIGINAL=true
                log_local "Aggressive cleanup mode enabled (activates all cleanup options)"
                shift # past argument
                ;;
            --cleanup-wav-files)
                CLEANUP_WAV=true
                log_local "Cleanup of WAV files enabled"
                shift # past argument
                ;;
            --cleanup-run-logs)
                CLEANUP_LOGS=true
                log_local "Cleanup of run logs enabled"
                shift # past argument
                ;;
            --cleanup-original-audio)
                CLEANUP_ORIGINAL=true
                log_local "Cleanup of original audio enabled"
                shift # past argument
                ;;
            --models)
                if [[ -n "$2" && "$2" != --* ]]; then
                    USER_SPECIFIED_MODELS="$2"
                    log_local "User specified Whisper models: $USER_SPECIFIED_MODELS"
                    shift 2 # past argument and value
                else
                    log_error_local "ERROR: --models option requires a non-empty argument."
                    # Optionally exit or handle error
                    shift # past argument if no value given or value looks like another option
                fi
                ;;
            --timeout-multiplier)
                if [[ -n "$2" && "$2" != --* && "$2" =~ ^[0-9]+$ ]]; then # Basic check for integer
                    USER_SPECIFIED_TIMEOUT_MULTIPLIER="$2"
                    log_local "User specified timeout multiplier: $USER_SPECIFIED_TIMEOUT_MULTIPLIER"
                    shift 2 # past argument and value
                else
                    log_error_local "ERROR: --timeout-multiplier option requires an integer argument."
                    # Optionally exit or handle error
                    if [[ -n "$2" && "$2" != --* ]]; then shift 2; else shift; fi # try to shift past
                fi
                ;;
            *)
                log_warn_local "Unknown argument: $key"
                shift # past argument
                ;;
        esac
    done
    
    # Acquire lock
    if ! acquire_lock; then
        log_info_local "Could not acquire lock, another instance is likely running. This is a normal exit."
        display_status_message "i" "Info: Queue processor already running. Exiting."
        exit 0
    fi
    
    # Setup directories
    setup_directories
    
    # Check if process_audio.sh exists and is executable
    if [ ! -x "$PROCESS_AUDIO_SCRIPT" ]; then
        log_error_local "process_audio.sh not found or not executable: $PROCESS_AUDIO_SCRIPT"
        display_status_message "!" "Failed: process_audio.sh not found or not executable"
        exit 1
    fi
    
    # Find audio files in inbox
    log_local "Scanning inbox for audio files..."
    local audio_files
    audio_files=$(find_audio_files "$INBOX_DIR")
    
    if [ -z "$audio_files" ]; then
        log_local "No audio files found in inbox"
        display_status_message "i" "Info: No audio files found in inbox"
        exit 0
    fi
    
    local file_count
    file_count=$(echo "$audio_files" | wc -l)
    log_local "Found $file_count audio file(s) in inbox"
    
    # DEBUG: List all found files
    # log_local "DEBUG: Listing all found audio files:"
    # local file_index=1
    # while IFS= read -r file_path_debug; do 
    #     [ -z "$file_path_debug" ] && continue
    #     local basename_debug=$(basename "$file_path_debug")
    #     local file_size_debug="unknown"
    #     # This if condition would likely fail if file_path_debug contains timestamp and tab
    #     # if [ -f "$file_path_debug" ]; then 
    #     # file_size_debug=$(stat -c %s "$file_path_debug" 2>/dev/null || stat -f %z "$file_path_debug" 2>/dev/null || echo "unknown")
    #     # fi
    #     # log_local "DEBUG: File $file_index: '$basename_debug' (size: $file_size_debug bytes) (full path: '$file_path_debug')"
    #     # file_index=$((file_index + 1))
    # done <<< "$audio_files" # This uses audio_files before the main loop logic might re-evaluate paths

    # Process files one by one (oldest first)
    local processed_count=0
    local success_count=0
    local failure_count=0
    
    while IFS= read -r file_path_from_find; do
        [ -z "$file_path_from_find" ] && continue
        
        # Ensure we are working with a clean file path.
        # Attempt to remove the leading 'timestamp<literal \t>' part.
        log_local "DEBUG_CLEANING: BEFORE strip: file_path_from_find is: '${file_path_from_find}'"
        local current_file_path
        # current_file_path="${file_path_from_find#*$'	'}" # Previous attempt, failed (looking for real TAB)
        # current_file_path=$(echo "$file_path_from_find" | sed 's/^[0-9]*\t//') # Previous sed attempt (real TAB)
        # current_file_path=$(echo "$file_path_from_find" | awk -F'\t' '{print $2}') # Previous awk attempt (looking for real TAB), resulted in empty string
        current_file_path=$(echo "$file_path_from_find" | awk -F'\\\\t' '{print $2}') # Target literal backslash-t
        log_local "DEBUG_CLEANING: AFTER strip: current_file_path is: '${current_file_path}'"

        local basename
        basename=$(basename "$current_file_path")
        
        # Check if already processed
        if is_already_processed "$current_file_path"; then
            log_local "Skipping already processed file: $basename"
            # Move to completed directory to clear inbox
            # Ensure the path used for mv is the correct one
            if [ -f "$current_file_path" ]; then # Check if the source file actually exists
                 mv "$current_file_path" "$COMPLETED_DIR/"
            else
                 # If the current_file_path (which should be from inbox) doesn't exist,
                 # it might be that the input to the loop was just the basename or something unexpected.
                 # Try to move based on INBOX_DIR and basename as a fallback.
                 log_warn_local "File '$current_file_path' not found directly. Attempting move from inbox: $INBOX_DIR/$basename"
                 if [ -f "$INBOX_DIR/$basename" ]; then
                    mv "$INBOX_DIR/$basename" "$COMPLETED_DIR/"
                 else
                    log_error_local "Could not find or move supposedly already processed file: $basename from $current_file_path or $INBOX_DIR/$basename"
                 fi
            fi
            continue
        fi
        
        # Process the file
        if process_file "$current_file_path"; then
            success_count=$((success_count + 1))
        else
            # Check the exit code of the last command, which is process_file
            last_exit_code=$?
            if [ "$last_exit_code" -eq 10 ]; then
                log_info_local "File processing for $basename will be retried; not counted as failure."
                # Not incrementing failure_count for retryable lock issues
            else
                failure_count=$((failure_count + 1))
            fi
        fi
        
        processed_count=$((processed_count + 1))
        
        # Only process one file per run to avoid long-running processes
        # # TODO: remove this once we have a more efficient way to process files
        # log_info_local "Processed 1 file this run. Exiting to allow next cron cycle."
        # break
        
    done <<< "$audio_files"
    
    display_status_message "x" "Completed: Queue Processor ($processed_count processed, $success_count success, $failure_count failed)"
}

# * Script Entry Point
main "$@" 