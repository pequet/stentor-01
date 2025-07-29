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
#   Main script for Stentor audio processing workflow.
#   Handles input validation, conversion to workable WAV, 
#   segmentation, transcription, and output generation.
#   AUTOMATION ENHANCEMENTS:
#   - Exit codes: 0=success, 1=processing failure, 2=validation failure
#   - Standardized output: transcript path on success, error to stderr on failure
#   - Internal locking to prevent concurrent execution
#
# Usage:
#   ./process_audio.sh [--cleanup-temp-audio] <input_audio_file_path> [whisper_model_list] [timeout_duration_multiplier]
#
# Exit Codes:
#   0: Success - Transcription completed successfully.
#   1: Processing Failure - An error occurred during audio processing or transcription.
#   2: Validation Failure - Invalid input, missing dependencies, or setup error.
#   10: Locked - Another instance is running or lock is fresh; safe to retry.
#
# Example:
#   ./process_audio.sh --cleanup-temp-audio "./my audio with spaces & chars!.mp3" medium.en
#   ./process_audio.sh "/path/to/another_audio.wav"
#
# Options:
#   --cleanup-temp-audio        Optional. If present, temporary audio files (converted WAV, segments)
#                               will be deleted after successful processing. Logs and transcripts are kept.
#   [whisper_model_list] Optional. Comma-separated list of Whisper models to try (e.g., "tiny.en,base.en").
#                        Defaults to "tiny.en". The script will try them in order.
#   [timeout_duration_multiplier] Optional. Positive integer to multiply segment duration by for dynamic timeout.
#                                 Defaults to 5.
#
# Dependencies:
#   - ffmpeg: For audio conversion and manipulation.
#   - ffprobe: For audio analysis (part of ffmpeg).
#   - bc: For floating point arithmetic.
#   - sed: For text manipulation.
#   - date: For timestamping.
#   - md5sum or md5: For generating file hashes.
#   - whisper-cli: The Whisper.cpp command-line interface (path configurable via WHISPER_PATH).
#   - timeout: For running Whisper with a timeout.
#
# Changelog:
#   1.0.0 - 2025-05-25 - Initial release with core processing, segmentation, and multi-model transcription.
#   1.0.1 - 2025-06-05 - Add exit code 10 for lock contention to allow queue managers to retry.
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
LOG_FILE_PATH="$HOME/.stentor/logs/process_audio.log"

# * Global Variables and Configuration

# ** Lock File Configuration
LOCK_FILE="$HOME/.stentor/process_audio.lock"
LOCK_TIMEOUT=7200  # 2 hours in seconds
LOCK_ACQUIRED_BY_THIS_PROCESS=false # Flag to track if this instance acquired the lock

# ** Core Processing Configuration
TARGET_SAMPLE_RATE=16000
TARGET_CHANNELS=1
DEFAULT_WHISPER_MODEL_LIST="tiny.en" # Default if not provided; can be a single model or comma-separated list
ULTIMATE_FALLBACK_MODEL="tiny.en"    # Fallback if all else fails or if default list is just tiny
# SEGMENT_TIMEOUT_SECONDS=40         # Static timeout, replaced by dynamic calculation below

# ** Dynamic Timeout Configuration
DEFAULT_TIMEOUT_DURATION_MULTIPLIER=5      # Default multiply segment duration by this factor for timeout
MIN_TIMEOUT_SECONDS=30                     # Minimum timeout for any segment
MAX_TIMEOUT_SECONDS=600                    # Maximum timeout for any segment (10 minutes)

# ** Prompt Configuration for Whisper
MAX_TOTAL_PROMPT_CHARS=750           # Max characters for the entire combined prompt
INTER_SEGMENT_CONTEXT_LENGTH=200     # Desired characters for previous segment tail (will be word-trimmed)
MAX_DESCRIPTION_CHARS_FOR_PROMPT=400 # Max characters from description (will be word-trimmed)

PROCESSING_BASE_DIR="$HOME/stentor_processing_runs" # MOVED OUTSIDE REPO

# Default Whisper path (can be overridden by WHISPER_PATH environment variable)
DEFAULT_WHISPER_PATH="$HOME/src/whisper.cpp/build/bin/whisper-cli"


# * Lock Management Functions
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        local lock_file_age_info="(age not calculated)"
        local lock_file_age_seconds=-1

        print_debug "--- DEBUG LOCK START ---"
        print_debug "Lock file found: $LOCK_FILE"
        print_debug "Content of LOCK_FILE (PID read): '$lock_pid'"

        local current_time=$(date +%s)
        local file_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)

        if [[ -n "$file_mod_time" ]]; then
            lock_file_age_seconds=$((current_time - file_mod_time))
            lock_file_age_info="(Age: ${lock_file_age_seconds}s, Timeout: ${LOCK_TIMEOUT}s)"
            print_debug "Calculated lock_file_age_seconds: $lock_file_age_seconds"
            print_debug "LOCK_TIMEOUT: $LOCK_TIMEOUT"
            print_debug "Formatted lock_file_age_info: $lock_file_age_info"
        else
            lock_file_age_info="(could not determine age)"
            print_debug "Could not determine file_mod_time. lock_file_age_seconds remains $lock_file_age_seconds."
        fi

        local pid_check_command_exit_code
        if [[ -n "$lock_pid" ]]; then
            print_debug "Preparing to check PID $lock_pid with 'kill -0 $lock_pid'"
            kill -0 "$lock_pid" 2>/dev/null
            pid_check_command_exit_code=$?
            print_debug "'kill -0 $lock_pid' exit code: $pid_check_command_exit_code"
        else
            print_debug "lock_pid is empty. Assuming PID not running."
            pid_check_command_exit_code=1 # Simulate PID not running if lock_pid is empty
        fi

        if [[ "$pid_check_command_exit_code" -eq 0 ]]; then
            print_debug "BRANCH TAKEN: PID $lock_pid IS considered RUNNING."
            print_error "Another process_audio.sh instance is running (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
            print_debug "--- DEBUG LOCK END (PID RUNNING) ---"
            echo "ERROR: Another process_audio.sh instance is already running" >&2
            exit 10 # Exit with code 10 for lock contention; safe to retry.
        else
            print_debug "DEBUG BRANCH TAKEN: PID $lock_pid IS considered NOT RUNNING (or PID was empty)."
            if [[ "$lock_file_age_seconds" -ne -1 ]]; then # Age was successfully calculated
                print_debug "Comparing age: $lock_file_age_seconds > $LOCK_TIMEOUT ?"
                if [[ "$lock_file_age_seconds" -gt "$LOCK_TIMEOUT" ]]; then
                    print_debug "AGE COMPARISON TRUE. Lock IS STALE."
                    print_error "Removing stale lock file (PID: $lock_pid). Details: $lock_file_age_info. Lock file: $LOCK_FILE"
                    rm -f "$LOCK_FILE"
                else
                    print_debug "AGE COMPARISON FALSE. Lock IS NOT STALE ENOUGH."
                    print_error "ERROR: Lock file (PID: $lock_pid) exists but is not older than timeout. Details: $lock_file_age_info. Not removing. Lock file: $LOCK_FILE"
                    print_debug "--- DEBUG LOCK END (PID NOT RUNNING, NOT STALE ENOUGH) ---"
                    echo "ERROR: Another process_audio.sh instance may have just finished or its lock is fresh" >&2
                    exit 10 # Exit with code 10 for lock contention; safe to retry.
                fi
            else # Age could not be determined earlier
                print_debug "Age could not be calculated. Assuming stale and removing."
                print_error "WARNING: Could not determine age of lock file (PID: $lock_pid). Details: $lock_file_age_info. Assuming stale and removing. Lock file: $LOCK_FILE"
                rm -f "$LOCK_FILE"
            fi
        fi
    fi
    
    print_debug "Proceeding to create new lock file."
    mkdir -p "$(dirname "$LOCK_FILE")"
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED_BY_THIS_PROCESS=true # Set flag as lock is acquired by this process
    print_debug "--- DEBUG LOCK END (NEW LOCK CREATED or NO LOCK INITIALLY) ---"
    log_info "Lock acquired successfully (PID: $$)"
    return 0
}

release_lock() {
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        print_debug "release_lock called by owning process (PID: $$). Removing $LOCK_FILE"
        rm -f "$LOCK_FILE"
        log_info "Lock released successfully (PID: $$)"
    else
        print_debug "release_lock called, but lock not owned by this process (PID: $$). Lock file $LOCK_FILE not removed by this instance."
        # It might be useful to log if the lock file still exists and who owns it, if not this process
        if [ -f "$LOCK_FILE" ]; then
            local current_owner_pid
            current_owner_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
            log_info "DEBUG: Lock file $LOCK_FILE still exists. Current content (PID): $current_owner_pid. Current script PID: $$_this_instance."
        else
            log_info "DEBUG: Lock file $LOCK_FILE not found when release_lock was called by non-owning process (PID: $$)."
        fi
    fi
}

# * Dependency Checking
check_dependencies() {
    local missing_deps=()
    
    # Check for basic tools
    for cmd in ffmpeg ffprobe bc sed date md5sum md5; do
        if ! command -v "$cmd" &> /dev/null; then
            # Special case for md5/md5sum
            if [ "$cmd" = "md5" ] && command -v md5sum &> /dev/null; then
                continue
            elif [ "$cmd" = "md5sum" ] && command -v md5 &> /dev/null; then
                continue
            fi
            missing_deps+=("$cmd")
        fi
    done
    
    # Check for Whisper
    WHISPER_PATH=${WHISPER_PATH:-$DEFAULT_WHISPER_PATH}
    if [ ! -x "$WHISPER_PATH" ]; then
        print_error "ERROR: Whisper not found at $WHISPER_PATH"
        print_error "Please ensure Whisper is installed and either:"
        print_error "1. Available at $DEFAULT_WHISPER_PATH"
        print_error "2. Or set WHISPER_PATH environment variable to its location"
        echo "ERROR: Whisper not found at $WHISPER_PATH" >&2
        exit 2
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "ERROR: Missing required dependencies: ${missing_deps[*]}"
        print_error "Please install the missing dependencies and try again."
        echo "ERROR: Missing dependencies: ${missing_deps[*]}" >&2
        exit 2
    fi
    
    log_info "All dependencies verified."
}

# Function to ensure a directory exists
ensure_directory_exists() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        log_info "Directory $dir_path does not exist. Creating..."
        mkdir -p "$dir_path"
        if [ $? -ne 0 ]; then
            print_error "Failed to create directory: $dir_path"
            exit 1 # Critical error, cannot proceed
        fi
        log_info "Successfully created directory: $dir_path"
    fi
}

# * Script Cleanup and Exit Function
cleanup_and_exit() {
    local exit_code=$1
    local message="${2:-Script exiting}"
    local absolute_transcript_path=""

    # Determine absolute transcript path early, IF successful
    if [ "$exit_code" -eq 0 ] && [ -n "${TRANSCRIPT_CLEAN_FILE:-}" ] && [ -f "${TRANSCRIPT_CLEAN_FILE:-}" ]; then
        if command -v realpath &> /dev/null; then
            absolute_transcript_path=$(realpath "$TRANSCRIPT_CLEAN_FILE")
        elif command -v readlink &> /dev/null; then
            absolute_transcript_path=$(readlink -f "$TRANSCRIPT_CLEAN_FILE")
        else
            if [[ "$TRANSCRIPT_CLEAN_FILE" = /* ]]; then
                absolute_transcript_path="$TRANSCRIPT_CLEAN_FILE"
            else
                absolute_transcript_path="$(cd "$(dirname "$TRANSCRIPT_CLEAN_FILE")" && pwd)/$(basename "$TRANSCRIPT_CLEAN_FILE")"
            fi
        fi
    fi

    # Release lock before exiting
    release_lock
    
    # Add cleanup of temporary audio files
    if [ "$CLEANUP_TEMP_AUDIO_FLAG" = "true" ] && [ "$exit_code" -eq 0 ]; then
        log_info "--cleanup-temp-audio flag is set and script succeeded. Removing temporary audio files."
        if [ -n "${WORKABLE_WAV_FILE:-}" ] && [ -f "$WORKABLE_WAV_FILE" ]; then
            log_info "Removing workable WAV file: $WORKABLE_WAV_FILE"
            rm -f "$WORKABLE_WAV_FILE"
        fi
        if [ -n "${SEGMENTS_DIR:-}" ] && [ -d "$SEGMENTS_DIR" ]; then
            log_info "Removing segments directory: $SEGMENTS_DIR"
            rm -rf "$SEGMENTS_DIR"
        fi
    elif [ "$exit_code" -eq 0 ]; then
        log_info "Script succeeded. Temporary audio files preserved as --cleanup-temp-audio flag was not set."
    fi
    
    # Determine final message and output path if successful
    if [ "$exit_code" -eq 0 ] && [ -n "$absolute_transcript_path" ]; then
        log_info "$message with code $exit_code - SUCCESS"
        # Output the absolute path to the transcript file for automation scripts - THIS MUST BE LAST ON STDOUT
        echo "$absolute_transcript_path"
    else
        log_info "$message with code $exit_code - FAILURE" 
        if [ "$exit_code" -ne 0 ]; then
            echo "ERROR: $message" >&2 
        fi
    fi

    exit "$exit_code"
}

# * Signal Traps
trap 'cleanup_and_exit 1 "Script interrupted by signal (INT/TERM)"' INT TERM
trap 'cleanup_and_exit $? "Script finished"' EXIT # Handles normal exit and exit due to set -e

# * Main Script Logic
main() {
    print_step "Starting: Audio Processing Workflow"

    # Initialize flag for cleanup
    CLEANUP_TEMP_AUDIO_FLAG=false

    # Acquire lock first
    if ! acquire_lock; then
        print_error "Could not acquire lock. Exiting."
        print_error "Failed: Could not acquire lock"
        exit 1 # Exit code for lock failure can be specific if needed by queue manager
    fi

    # Ensure the main processing base directory exists
    ensure_directory_exists "$PROCESSING_BASE_DIR"

    # Check dependencies before proceeding
    check_dependencies

    # ** Argument Parsing & Initial Validation
    log_info "Parsing arguments..."

    POSITIONAL_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cleanup-temp-audio)
                CLEANUP_TEMP_AUDIO_FLAG=true
                log_info "--cleanup-temp-audio flag detected."
                shift # past argument
                ;;
            *)
                POSITIONAL_ARGS+=("$1") # save positional arg
                shift # past argument
                ;;
        esac
    done

    # Restore positional arguments for existing logic
    set -- "${POSITIONAL_ARGS[@]}"

    if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then # Allow 1 to 3 positional arguments
        print_error "ERROR: Incorrect number of positional arguments (expected 1-3)."
        echo "Usage: $0 [--cleanup-temp-audio] <input_audio_file_path> [whisper_model_list] [timeout_duration_multiplier]"
        print_error "Failed: Incorrect number of positional arguments"
        exit 2
    fi

    INPUT_AUDIO_FILE_RAW="${1:-}" # Use ${1:-} to handle if it's empty after shifts
    if [ -z "$INPUT_AUDIO_FILE_RAW" ]; then
        print_error "ERROR: Input audio file path is missing."
        echo "Usage: $0 [--cleanup-temp-audio] <input_audio_file_path> [whisper_model_list] [timeout_duration_multiplier]"
        print_error "Failed: Input audio file path missing"
        exit 2
    fi

    USER_PROVIDED_MODELS_STRING="${2:-$DEFAULT_WHISPER_MODEL_LIST}"
    USER_PROVIDED_TIMEOUT_MULTIPLIER="${3:-}"

    # Handle optional third argument for timeout multiplier
    TIMEOUT_DURATION_MULTIPLIER=$DEFAULT_TIMEOUT_DURATION_MULTIPLIER # Default value

    if [ -n "$USER_PROVIDED_TIMEOUT_MULTIPLIER" ]; then
        # Validate if it's a positive integer
        if [[ "$USER_PROVIDED_TIMEOUT_MULTIPLIER" =~ ^[1-9][0-9]*$ ]]; then
            TIMEOUT_DURATION_MULTIPLIER=$USER_PROVIDED_TIMEOUT_MULTIPLIER
            log_info "User provided timeout duration multiplier: $TIMEOUT_DURATION_MULTIPLIER"
        else
            log_warn "WARNING: Invalid timeout_duration_multiplier '$USER_PROVIDED_TIMEOUT_MULTIPLIER' provided. Must be a positive integer. Using default: $DEFAULT_TIMEOUT_DURATION_MULTIPLIER."
        fi
    else
        log_info "No timeout duration multiplier provided by user. Using default: $DEFAULT_TIMEOUT_DURATION_MULTIPLIER"
    fi

    log_info "Raw input audio file: '$INPUT_AUDIO_FILE_RAW'"
    log_info "User provided models string: '$USER_PROVIDED_MODELS_STRING' (Default: '$DEFAULT_WHISPER_MODEL_LIST')"
    log_info "Ultimate fallback model: '$ULTIMATE_FALLBACK_MODEL'"
    # log "Segment timeout: $SEGMENT_TIMEOUT_SECONDS seconds"

    if [ ! -f "$INPUT_AUDIO_FILE_RAW" ]; then
        print_error "ERROR: Input audio file not found: '$INPUT_AUDIO_FILE_RAW'"
        print_error "Failed: Input audio file not found: '$INPUT_AUDIO_FILE_RAW'"
        exit 2
    fi

    log_info "Input file exists. Proceeding with initial processing."

    # Create a main processing directory for this specific run
    original_basename=$(basename "$INPUT_AUDIO_FILE_RAW")

    # Generate a hash of the original basename for the directory name
    # On Linux, it would be 'echo -n "$original_basename" | md5sum | awk '{print $1}''
    # On macOS, 'md5 -q' is used.
    if ! command -v md5sum &> /dev/null && ! command -v md5 &> /dev/null; then
        print_error "ERROR: Neither 'md5sum' (Linux) nor 'md5' (macOS) command found. Cannot generate file hash."
        echo "ERROR: md5 command not found" >&2
        exit 2
    fi

    file_hash=""
    if command -v md5sum &> /dev/null; then # Linux preferred
        file_hash=$(echo -n "$original_basename" | md5sum | awk '{print $1}')
    elif command -v md5 &> /dev/null; then # macOS fallback
        file_hash=$(echo -n "$original_basename" | md5 -q)
    fi

    if [ -z "$file_hash" ]; then
        print_error "ERROR: Failed to generate file hash for '$original_basename'."
        echo "ERROR: Failed to generate file hash" >&2
        exit 2
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_RUN_DIR="$PROCESSING_BASE_DIR/${file_hash}_${TIMESTAMP}"

    # Sanitize original_basename for potential use in info file or suggested final output name
    # This is NOT used for the run directory or internal working file paths anymore.
    sanitized_basename_for_info=$(echo "${original_basename%.*}" | sed 's/[^a-zA-Z0-9_.-]/_/g')

    mkdir -p "$CURRENT_RUN_DIR"
    if [ ! -d "$CURRENT_RUN_DIR" ]; then
        print_error "ERROR: Could not create run directory: $CURRENT_RUN_DIR"
        print_error "Failed: Could not create run directory"
        exit 2
    fi
    log_info "Created run directory: $CURRENT_RUN_DIR (Original basename: '$original_basename')"

    # ** Prepare Context for Whisper Prompts (Title & Description)
    log_info "[WHISPER PROMPT] Preparing context for Whisper prompts..."
    # Extract a cleaner title from the original basename
    # Removes ' [ID].ext' and replaces underscores with spaces
    extracted_title=$(echo "$original_basename" | sed -E 's/\s*\[([a-zA-Z0-9_-]+)\]\.[a-zA-Z0-9]+$//' | sed 's/_/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log_info "[WHISPER PROMPT] Extracted title for prompt: '$extracted_title'"

    description_file_path="${INPUT_AUDIO_FILE_RAW%.*}.description"
    description_content_raw=""
    if [ -f "$description_file_path" ]; then
        description_content_raw=$(cat "$description_file_path" 2>/dev/null || echo "")
        # Sanitize description: remove newlines, excessive spaces
        description_content_processed=$(echo "$description_content_raw" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Trim to max length and then to last word boundary
        description_content_for_prompt=$(echo "$description_content_processed" | cut -c1-$MAX_DESCRIPTION_CHARS_FOR_PROMPT)
        if [ ${#description_content_processed} -gt $MAX_DESCRIPTION_CHARS_FOR_PROMPT ]; then # Only trim to word if it was actually cut
            description_content_for_prompt=$(echo "$description_content_for_prompt" | sed -E 's/(.*)[[:space:]]+[^[:space:]]*$/\1/')
        fi
        log_info "[WHISPER PROMPT] Found and read description file: $description_file_path. Processed for prompt (${#description_content_for_prompt} chars): '${description_content_for_prompt:0:100}...'"
    else
        description_content_for_prompt=""
        log_info "[WHISPER PROMPT] Description file not found: $description_file_path"
    fi
    # ** End Prepare Context

    # ** Stage 1: Input Processing & WAV Conversion
    log_info "Starting Stage 1: Input Processing & WAV Conversion..."

    # Define output filenames within the run directory using generic names
    WORKABLE_WAV_FILE="$CURRENT_RUN_DIR/audio_workable.wav"
    TRANSCRIPT_TXT_FILE="$CURRENT_RUN_DIR/audio_transcript.md" # Detailed transcript with headers
    TRANSCRIPT_CLEAN_FILE="$CURRENT_RUN_DIR/audio_transcript.txt" # Clean text-only transcript
    INFO_MD_FILE="$CURRENT_RUN_DIR/processing_info.md"       # For future stages

    log_info "Target workable WAV: $WORKABLE_WAV_FILE"
    log_info "Target transcript file (detailed): $TRANSCRIPT_TXT_FILE"
    log_info "Target transcript file (clean): $TRANSCRIPT_CLEAN_FILE"
    log_info "Target info file (future): $INFO_MD_FILE"

    # Determine input file type (simple check using extension, can be enhanced with ffprobe/file command)
    input_ext_lowercase=$(echo "${INPUT_AUDIO_FILE_RAW##*.}" | tr '[:upper:]' '[:lower:]')
    log_info "Detected input file extension: .$input_ext_lowercase"

    # FFmpeg command for conversion/standardization
    # -y: overwrite output files without asking
    # -hide_banner: suppress printing banner
    # -loglevel error: show only errors
    # -ac $TARGET_CHANNELS: target audio channels
    # -ar $TARGET_SAMPLE_RATE: target audio sample rate
    # -c:a pcm_s16le: target audio codec (signed 16-bit PCM)
    ffmpeg_conversion_cmd=(
        "ffmpeg" \
        -y -hide_banner -loglevel error \
        -i "$INPUT_AUDIO_FILE_RAW" \
        -ac "$TARGET_CHANNELS" \
        -ar "$TARGET_SAMPLE_RATE" \
        -c:a pcm_s16le \
        "$WORKABLE_WAV_FILE" # Use the new generic name
    )

    needs_conversion=true # Assume conversion is needed by default

    if [ "$input_ext_lowercase" == "wav" ]; then
        log_info "Input is a WAV file. Checking if it meets target format ($TARGET_SAMPLE_RATE Hz, $TARGET_CHANNELS ch, pcm_s16le)..."
        # Use ffprobe to get detailed info. Ensure ffprobe is installed.
        if ! command -v ffprobe &> /dev/null; then
            print_error "ERROR: ffprobe command not found. Cannot verify WAV format. Please install ffprobe (usually part of ffmpeg package)."
            print_error "Failed: ffprobe command not found"
            exit 2
        fi
        
        # Read ffprobe output line by line into an array
        mapfile -t probe_lines < <(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels,codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT_AUDIO_FILE_RAW")

        current_sample_rate="unknown"
        current_channels="unknown"
        current_codec_name="unknown"

        # Assign based on the observed output order from the DEBUG logs
        # DEBUG: Value read for current_sample_rate: [pcm_s16le] -> probe_lines[0] was codec
        # DEBUG: Value read for current_channels: [16000]     -> probe_lines[1] was sample rate
        # DEBUG: Value read for current_codec_name: [1]         -> probe_lines[2] was channels

        if [ ${#probe_lines[@]} -ge 1 ]; then current_codec_name=${probe_lines[0]}; fi # First line was codec
        if [ ${#probe_lines[@]} -ge 2 ]; then current_sample_rate=${probe_lines[1]}; fi # Second line was sample rate
        if [ ${#probe_lines[@]} -ge 3 ]; then current_channels=${probe_lines[2]}; fi    # Third line was channels

        # Ensure the DEBUG lines are definitely present for this next test
        log_info "DEBUG: Value read for current_sample_rate: [$current_sample_rate]"
        log_info "DEBUG: Value read for current_channels: [$current_channels]"
        log_info "DEBUG: Value read for current_codec_name: [$current_codec_name]"

        log_info "Probed WAV format: Sample Rate=$current_sample_rate, Channels=$current_channels, Codec=$current_codec_name"

        if [ "$current_sample_rate" == "$TARGET_SAMPLE_RATE" ] &&\
           [ "$current_channels" == "$TARGET_CHANNELS" ] &&\
           ( [ "$current_codec_name" == "pcm_s16le" ] || [ "$current_codec_name" == "pcm_s16be" ] ); then # Accept BE too, ffmpeg handles it
            log_info "Input WAV file already meets target format criteria. Copying to workable WAV location."
            # Instead of full ffmpeg conversion, just copy the file.
            # This is faster and preserves metadata if desired (though ffmpeg conversion would also copy most).
            cp "$INPUT_AUDIO_FILE_RAW" "$WORKABLE_WAV_FILE"
            if [ $? -ne 0 ]; then
                print_error "ERROR: Failed to copy existing WAV to workable location. Attempting conversion instead."
                needs_conversion=true # Fallback to conversion
            else
                needs_conversion=false
            fi
        else
            log_info "Input WAV does not meet target format. Conversion is required."
            needs_conversion=true
        fi
    else
        log_info "Input file is not WAV (or extension is different). Full conversion is required."
        needs_conversion=true
    fi

    if [ "$needs_conversion" == true ]; then
        log_info "Executing FFmpeg conversion: ${ffmpeg_conversion_cmd[*]}"
        "${ffmpeg_conversion_cmd[@]}"
        if [ $? -ne 0 ]; then
            print_error "ERROR: FFmpeg conversion failed for '$INPUT_AUDIO_FILE_RAW'."
            # ffmpeg already prints errors to stderr due to -loglevel error, so no need to capture its output here usually.
            print_error "Failed: FFmpeg conversion for '$INPUT_AUDIO_FILE_RAW'"
            exit 1
        fi
        log_info "FFmpeg conversion successful. Workable WAV created: $WORKABLE_WAV_FILE"
    fi

    if [ ! -f "$WORKABLE_WAV_FILE" ]; then
        print_error "ERROR: Workable WAV file was not created: $WORKABLE_WAV_FILE"
        print_error "Failed: Workable WAV file not created"
        exit 1
    fi

    log_info "Stage 1 complete. Workable WAV is at: $WORKABLE_WAV_FILE"

    # Placeholder for workable WAV: $workable_wav_file_placeholder # This line can be removed now
    log_info "Initial setup and argument processing complete."

    # ** Stage 2: Audio Segmentation (Optional)
    log_info "Starting Stage 2: Audio Segmentation Analysis..."

    # Configuration for silence detection
    SILENCE_DURATION_THRESHOLD=1.0  # Silence longer than this will trigger a split (seconds)
    SILENCE_NOISE_THRESHOLD="-30dB" # Audio levels below this are considered silence
    SEGMENT_PADDING="0.25"         # Padding around segments to avoid cutting words (seconds)
    MIN_SEGMENT_DURATION=1.0       # Minimum duration for a valid segment (seconds)

    # First, analyze silence points using ffmpeg silencedetect filter
    log_info "Analyzing silence points in audio..."
    silence_detection_output=$(ffmpeg -hide_banner -i "$WORKABLE_WAV_FILE" \
        -af silencedetect=noise=${SILENCE_NOISE_THRESHOLD}:duration=${SILENCE_DURATION_THRESHOLD} \
        -f null - 2>&1)

    # Initialize arrays with empty values to avoid unbound variable errors
    silence_starts=()
    silence_ends=()
    total_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORKABLE_WAV_FILE")

    log_info "Parsing silence detection output..."
    while IFS= read -r line; do
        if [[ $line =~ silence_start:[[:space:]]*([0-9.]*) ]]; then
            silence_starts+=("${BASH_REMATCH[1]}")
            log_info "DEBUG: Found silence start at ${BASH_REMATCH[1]} seconds"
        elif [[ $line =~ silence_end:[[:space:]]*([0-9.]*) ]]; then
            silence_ends+=("${BASH_REMATCH[1]}")
            log_info "DEBUG: Found silence end at ${BASH_REMATCH[1]} seconds"
        fi
    done < <(echo "$silence_detection_output")

    # Count the number of segments we'll create (add +1 because n silence points create n+1 segments)
    num_segments=${#silence_starts[@]}
    log_info "Detected $num_segments silence points in audio (potentially $((num_segments + 1)) segments)"

    # Create segments directory regardless of segmentation method
    SEGMENTS_DIR="$CURRENT_RUN_DIR/segments"
    mkdir -p "$SEGMENTS_DIR"

    if [ "${#silence_starts[@]}" -eq 0 ]; then
        log_info "No significant silence periods detected. Processing audio as a single segment."
        
        # Create a symbolic link to the workable WAV as segment_001.wav
        ln -sf "../audio_workable.wav" "$SEGMENTS_DIR/segment_001.wav"
        log_info "Created symbolic link for single segment processing"
        
        # Create segments info file
        {
            echo "# Audio Segmentation Information"
            echo "- Total Duration: ${total_duration} seconds"
            echo "- Number of Segments: 1"
            echo "- Segmentation Method: None (single file)"
            echo "- Segment Files:"
            echo "  1. segment_001.wav (full audio)"
        } > "$CURRENT_RUN_DIR/segmentation_info.md"
    else
        log_info "Creating segments based on detected silence points..."
        
        # Initialize segment info for the markdown file
        {
            echo "# Audio Segmentation Information"
            echo "- Total Duration: ${total_duration} seconds"
            echo "- Number of Segments: TBD (will be updated)"
            echo "- Segmentation Method: Silence Detection"
            echo "- Silence Detection Parameters:"
            echo "  - Duration Threshold: ${SILENCE_DURATION_THRESHOLD}s"
            echo "  - Noise Threshold: ${SILENCE_NOISE_THRESHOLD}"
            echo "  - Segment Padding: ${SEGMENT_PADDING}s"
            echo "  - Minimum Segment Duration: ${MIN_SEGMENT_DURATION}s"
            echo "- Segment Files:"
        } > "$CURRENT_RUN_DIR/segmentation_info.md"
        
        # Create segments using ffmpeg
        current_start=0
        segment_number=1
        valid_segments=0
        
        for i in "${!silence_starts[@]}"; do
            silence_start="${silence_starts[$i]}"
            # Calculate segment duration
            duration=$(echo "$silence_start - $current_start" | bc)
            
            # Skip segments that are too short
            if (( $(echo "$duration < $MIN_SEGMENT_DURATION" | bc -l) )); then
                log_info "Skipping segment $segment_number - duration ${duration}s is below minimum threshold of ${MIN_SEGMENT_DURATION}s"
                # If we skip a segment, we'll use the end of its silence period as the start of the next one
                if [ -n "${silence_ends[$i]}" ]; then
                    current_start=$(echo "${silence_ends[$i]} - $SEGMENT_PADDING" | bc)
                fi
                continue
            fi
            
            # Add padding to segment end (but don't exceed silence end)
            padded_end=$(echo "$silence_start + $SEGMENT_PADDING" | bc)
            if [ -n "${silence_ends[$i]}" ]; then
                if (( $(echo "$padded_end > ${silence_ends[$i]}" | bc -l) )); then
                    padded_end=${silence_ends[$i]}
                fi
            fi
            
            # Format segment number with leading zeros
            segment_name=$(printf "segment_%03d.wav" $segment_number)
            
            log_info "Creating segment $segment_number (${duration}s) from $current_start to $silence_start"
            
            # Extract segment using ffmpeg with error handling
            if ! ffmpeg -hide_banner -loglevel error -i "$WORKABLE_WAV_FILE" \
                -ss "$current_start" -t "$duration" \
                "$SEGMENTS_DIR/$segment_name"; then
                print_error "WARNING: Failed to create segment $segment_number. Skipping..."
                # Clean up the potentially partially written file
                rm -f "$SEGMENTS_DIR/$segment_name"
            else
                # Only count and document successfully created segments
                valid_segments=$((valid_segments + 1))
                echo "  $segment_number. $segment_name (${duration}s)" >> "$CURRENT_RUN_DIR/segmentation_info.md"
            fi
            
            # Update for next iteration
            current_start=$(echo "${silence_ends[$i]} - $SEGMENT_PADDING" | bc)
            ((segment_number++))
        done
        
        # Handle the final segment
        if [ "$current_start" != "$total_duration" ]; then
            segment_name=$(printf "segment_%03d.wav" $segment_number)
            duration=$(echo "$total_duration - $current_start" | bc)
            
            # Only process final segment if it meets minimum duration
            if (( $(echo "$duration >= $MIN_SEGMENT_DURATION" | bc -l) )); then
                log_info "Creating final segment $segment_number (${duration}s) from $current_start to end"
                
                if ! ffmpeg -hide_banner -loglevel error -i "$WORKABLE_WAV_FILE" \
                    -ss "$current_start" -t "$duration" \
                    "$SEGMENTS_DIR/$segment_name"; then
                    print_error "WARNING: Failed to create final segment. Skipping..."
                    rm -f "$SEGMENTS_DIR/$segment_name"
                else
                    valid_segments=$((valid_segments + 1))
                    echo "  $segment_number. $segment_name (${duration}s)" >> "$CURRENT_RUN_DIR/segmentation_info.md"
                fi
            else
                log_info "Skipping final segment - duration ${duration}s is below minimum threshold of ${MIN_SEGMENT_DURATION}s"
            fi
        fi
        
        # Update the segment count in the info file
        sed -i.bak "s/Number of Segments: TBD/Number of Segments: $valid_segments/" "$CURRENT_RUN_DIR/segmentation_info.md"
        rm -f "${CURRENT_RUN_DIR}/segmentation_info.md.bak"
    fi

    log_info "Stage 2 complete. Audio segments created in: $SEGMENTS_DIR"
    log_info "Segmentation information saved to: $CURRENT_RUN_DIR/segmentation_info.md"

    # Script will continue with transcription stage next...

    # ** Stage 3: Transcription
    log_info "Starting Stage 3: Transcription Processing..."

    # Ensure transcript directory exists (fix the file creation error)
    transcript_dir=$(dirname "$TRANSCRIPT_TXT_FILE")
    mkdir -p "$transcript_dir"

    # Initialize the transcript file with a header
    {
        echo "# Audio Transcript"
        echo "- Original File: $original_basename"
        echo "- Processing Date: $(date +'%Y-%m-%d %H:%M:%S %z')"
        echo "- Whisper Model(s) Specified: $USER_PROVIDED_MODELS_STRING"
        echo "- Effective Timeout Multiplier: $TIMEOUT_DURATION_MULTIPLIER"
        echo ""
        echo "## Transcription"
        echo ""
    } > "$TRANSCRIPT_TXT_FILE"

    # Initialize the clean transcript file (empty, text-only)
    > "$TRANSCRIPT_CLEAN_FILE"

    # Track transcription statistics
    transcription_start_time=$(date +%s)
    successful_segments=0
    failed_segments=0
    previous_chunk_transcript_tail="" # Initialize for inter-segment context
    # INTER_SEGMENT_CONTEXT_LENGTH defined globally now

    # Create temporary directory for Whisper output
    mkdir -p "$CURRENT_RUN_DIR/temp_whisper"

    # Process each segment
    for segment_file in "$SEGMENTS_DIR"/segment_*.wav; do
        if [ ! -f "$segment_file" ]; then
            log_info "No segment files found in $SEGMENTS_DIR"
            break
        fi

        segment_name=$(basename "$segment_file")
        segment_number=$(echo "$segment_name" | sed -n 's/segment_\([0-9]\{3\}\)\.wav/\1/p')
        
        log_info "Processing segment $segment_number: $segment_name"

        # Convert comma-separated string of user models to an array
        IFS=',' read -r -a models_to_try <<< "$USER_PROVIDED_MODELS_STRING"
        
        # Ensure the ultimate fallback is always an option if not already in the list
        # and if the initial list isn't just the fallback itself.
        already_contains_fallback=false
        for model in "${models_to_try[@]}"; do
            if [ "$model" == "$ULTIMATE_FALLBACK_MODEL" ]; then
                already_contains_fallback=true
                break
            fi
        done
        if [ "$already_contains_fallback" == false ] && ! ( [ "${#models_to_try[@]}" -eq 1 ] && [ "${models_to_try[0]}" == "$ULTIMATE_FALLBACK_MODEL" ] ); then
            models_to_try+=("$ULTIMATE_FALLBACK_MODEL")
        fi 
        # If the initial list was empty or only the fallback, and somehow it got duplicated, this unique step isn't strictly needed
        # but doesn't hurt. A more robust way would be to build a unique list from user + fallback.

        log_info "DEBUG: Effective models to try for segment $segment_number: ${models_to_try[*]}"

        transcription_successful=false
        attempt_num=0
        transcript_content=""
        final_model_used=""

        for current_model_name in "${models_to_try[@]}"; do
            attempt_num=$((attempt_num + 1))
            log_info "Attempt $attempt_num for segment $segment_number with model '$current_model_name'"

            # Check if the model file exists
            local model_file_path="$HOME/src/whisper.cpp/models/ggml-${current_model_name}.bin"
            if [ ! -f "$model_file_path" ]; then
                print_error "ERROR: Whisper model file not found for '$current_model_name' at: $model_file_path"
                # If it's the last model in the list and it's not found, then transcription will fail for this segment.
                # The loop will naturally continue if there are more models to try.
                # If this was the *only* or *last* model, the existing failure logic after the loop handles it.
                continue # Skip to the next model in models_to_try
            fi

            # ** [WHISPER PROMPT] Construct Prompt for Whisper
            current_prompt_string=""

            if [ -n "$extracted_title" ]; then
                current_prompt_string+="${extracted_title}. " 
            fi

            if [ -n "$description_content_for_prompt" ]; then
                current_prompt_string+="${description_content_for_prompt}. "
            fi

            if [ -n "$previous_chunk_transcript_tail" ]; then
                # If current_prompt_string is not empty (i.e., title and/or description was added)
                # and it already ends with a space (from the ". " added by title/desc),
                # then we append "... " directly.
                # If current_prompt_string is empty (only prev_chunk_tail will be used),
                # we also start with "... ".
                if [ -n "$current_prompt_string" ] && [[ ! "$current_prompt_string" =~ [[:space:]]$ ]]; then
                    # This is a fallback - normally title/desc ensure a trailing space.
                    current_prompt_string+=" " 
                fi
                current_prompt_string+="[...] " # Add separator before the previous chunk tail
                current_prompt_string+="$previous_chunk_transcript_tail"
            fi

            # Trim entire prompt to MAX_TOTAL_PROMPT_CHARS and then to word boundary
            if [ ${#current_prompt_string} -gt $MAX_TOTAL_PROMPT_CHARS ]; then
                final_prompt_string_temp=$(echo "$current_prompt_string" | cut -c1-$MAX_TOTAL_PROMPT_CHARS)
                # Trim to last word boundary
                final_prompt_string=$(echo "$final_prompt_string_temp" | sed -E 's/(.*)[[:space:]]+[^[:space:]]*$/\1/')
                log_info "[WHISPER PROMPT] DEBUG: Original combined prompt was too long (${#current_prompt_string} chars), truncated to ${#final_prompt_string} chars."
            else
                final_prompt_string="$current_prompt_string"
            fi
            # ** [WHISPER PROMPT] End Construct Prompt

            # Sanitize the prompt string: remove all internal double quotes.
            local sanitized_prompt_for_cmd
            # Remove all occurrences of " from final_prompt_string
            sanitized_prompt_for_cmd=$(echo "$final_prompt_string" | sed 's/"//g') 

            # Ensure any previous .txt file for this segment is removed before a new attempt
            rm -f "${segment_file}.txt"

            # ** Calculate Dynamic Timeout for this segment
            segment_duration_float=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$segment_file")
            if [[ -z "$segment_duration_float" || ! "$segment_duration_float" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                log_info "WARNING: Could not determine duration for segment $segment_name. Using MIN_SEGMENT_TIMEOUT_SECONDS ($MIN_TIMEOUT_SECONDS s)."
                actual_timeout_this_segment="$MIN_TIMEOUT_SECONDS"
            else
                calculated_timeout_float=$(echo "$segment_duration_float * $TIMEOUT_DURATION_MULTIPLIER" | bc)
                # Round to nearest integer
                calculated_timeout_int=$(printf "%.0f" "$calculated_timeout_float")
                
                actual_timeout_this_segment=$calculated_timeout_int
                
                if (( actual_timeout_this_segment < MIN_TIMEOUT_SECONDS )); then
                    log_info "DEBUG: Calculated timeout ($actual_timeout_this_segment s) is less than MIN_TIMEOUT_SECONDS ($MIN_TIMEOUT_SECONDS s). Using minimum."
                    actual_timeout_this_segment=$MIN_TIMEOUT_SECONDS
                fi
                
                if (( actual_timeout_this_segment > MAX_TIMEOUT_SECONDS )); then
                    log_info "DEBUG: Calculated timeout ($actual_timeout_this_segment s) is greater than MAX_TIMEOUT_SECONDS ($MAX_TIMEOUT_SECONDS s). Using maximum."
                    actual_timeout_this_segment=$MAX_TIMEOUT_SECONDS
                fi
                log_info "DEBUG: Segment $segment_name duration: $segment_duration_float s. Calculated dynamic timeout: $actual_timeout_this_segment s (Multiplier: $TIMEOUT_DURATION_MULTIPLIER, Min: $MIN_TIMEOUT_SECONDS s, Max: $MAX_TIMEOUT_SECONDS s)."
            fi
            # ** End Dynamic Timeout Calculation

            whisper_cmd=(
                "$WHISPER_PATH"
                "$segment_file"
                -m "$HOME/src/whisper.cpp/models/ggml-${current_model_name}.bin"
                --output-txt
            )
            # Add prompt if it was constructed
            if [ -n "$sanitized_prompt_for_cmd" ]; then # Use the sanitized version
                # When "${whisper_cmd[@]}" is expanded later, the shell ensures
                # that the content of "$sanitized_prompt_for_cmd" is passed as a single argument,
                # effectively quoting the whole string for whisper-cli.
                whisper_cmd+=(--prompt "$sanitized_prompt_for_cmd")
                log_info "[WHISPER PROMPT] DEBUG: Using SANITIZED (internal double quotes removed) prompt (first 100 chars): ${sanitized_prompt_for_cmd:0:100}..."
            else
                log_info "[WHISPER PROMPT] DEBUG: No prompt constructed for this segment."
            fi
            
            # Construct a string for logging that visually quotes arguments with spaces.
            local log_cmd_str="timeout $actual_timeout_this_segment"
            for arg in "${whisper_cmd[@]}"; do
                # If the argument contains a space, enclose it in double quotes for the log.
                if [[ "$arg" == *" "* ]]; then
                    log_cmd_str+=" \"$arg\""
                else
                    log_cmd_str+=" $arg"
                fi
            done
            log_info "DEBUG: Executing Whisper command: $log_cmd_str"
            
            log_info "DEBUG: Whisper path: $WHISPER_PATH"
            log_info "DEBUG: Model path: $HOME/src/whisper.cpp/models/ggml-${current_model_name}.bin"
            log_info "DEBUG: Segment file: $segment_file"
            
            # Run whisper with timeout. Redirect stdout to /dev/null (as we expect transcript in a file),
            # and stderr to a temporary file for later inspection.
            temp_stderr_file="${segment_file}.stderr.tmp"
            
            # Run whisper with timeout. Capture its exit code without set -e terminating the script.
            # If timeout itself succeeds (returns 0), whisper ran to completion (successfully or with its own error).
            # If timeout kills whisper (returns 124), that's the code we capture.
            # If timeout fails for other reasons (e.g., 125, 126, 127, 137), capture that.
            if timeout "$actual_timeout_this_segment" "${whisper_cmd[@]}" >/dev/null 2>"$temp_stderr_file"; then
                whisper_exit_code=0
            else
                whisper_exit_code=$?
            fi
            
            whisper_stderr=""
            if [ -f "$temp_stderr_file" ]; then
                whisper_stderr=$(cat "$temp_stderr_file")
                rm -f "$temp_stderr_file"
            fi
            
            log_info "DEBUG: Whisper exit code: $whisper_exit_code"        
            log_info "DEBUG: Whisper stderr (first 300 chars): ${whisper_stderr:0:300}"
            
            expected_txt_file="${segment_file}.txt"
            log_info "DEBUG: Expected transcript file: $expected_txt_file"

            if [ "$whisper_exit_code" -eq 124 ]; then # Specific exit code for timeout command
                print_error "ERROR: Whisper command timed out after $actual_timeout_this_segment seconds for model '$current_model_name' on segment $segment_number."
            elif [[ "$whisper_stderr" == *"error:"* ]] || [[ "$whisper_stderr" == *"usage:"* ]] || [[ "$whisper_stderr" == *"failed to load model"* ]] || [ "$whisper_exit_code" -ne 0 ]; then
                print_error "ERROR: Whisper command failed for model '$current_model_name' on segment $segment_number. Exit code: $whisper_exit_code"
                print_error "ERROR: Full Whisper stderr: $whisper_stderr"
            elif [ -f "$expected_txt_file" ] && [ -s "$expected_txt_file" ]; then # Check if file exists and is not empty
                transcript_content=$(cat "$expected_txt_file")
                log_info "DEBUG: Raw transcript content (${#transcript_content} chars) from '$current_model_name': '${transcript_content:0:100}...'"
                
                transcript_content=$(echo "$transcript_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                log_info "DEBUG: Trimmed transcript content (${#transcript_content} chars): '${transcript_content:0:100}...'"
                
                transcription_successful=true
                final_model_used="$current_model_name"
                log_info "Successfully transcribed segment $segment_number with model '$final_model_used' (Attempt $attempt_num)"
                break # Exit model retry loop on success
            else
                log_info "WARNING: No transcription output or empty file for segment $segment_number with model '$current_model_name'."
                if [ ! -f "$expected_txt_file" ]; then
                    print_error "ERROR: Expected transcript file not created: $expected_txt_file"
                elif [ ! -s "$expected_txt_file" ]; then
                    print_error "ERROR: Expected transcript file IS EMPTY: $expected_txt_file"
                fi
            fi
        done # End of model retry loop

        if [ "$transcription_successful" == true ]; then
            echo "--- Segment $segment_number (Model: $final_model_used) --- LOUD AND PROUD" >> "$TRANSCRIPT_TXT_FILE"
            echo "$transcript_content" >> "$TRANSCRIPT_TXT_FILE"
            echo -e "\n" >> "$TRANSCRIPT_TXT_FILE"
            
            echo "$transcript_content" >> "$TRANSCRIPT_CLEAN_FILE"
            echo "" >> "$TRANSCRIPT_CLEAN_FILE"
            
            successful_segments=$((successful_segments + 1))
            # Update tail for the next segment
            temp_tail=$(echo "$transcript_content" | tail -c $INTER_SEGMENT_CONTEXT_LENGTH)
            # Trim to word boundary
            if [ ${#temp_tail} -eq $INTER_SEGMENT_CONTEXT_LENGTH ] && [[ "$temp_tail" == *" "* ]]; then # Only trim if it was full length and contains a space
                 previous_chunk_transcript_tail=$(echo "$temp_tail" | sed -E 's/(.*)[[:space:]]+[^[:space:]]*$/\1/')
            else
                 previous_chunk_transcript_tail=$(echo "$temp_tail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') # Just trim whitespace if no space to break on or shorter
            fi

            # ADDED: Trim the first word (partial or full) and subsequent space(s) from the beginning
            if [[ "$previous_chunk_transcript_tail" == *" "* ]]; then # Only if there's a space to identify the first word
                previous_chunk_transcript_tail=$(echo "$previous_chunk_transcript_tail" | sed -E 's/^[^[:space:]]*[[:space:]]*//')
            fi
            # END ADDED SECTION

            log_info "DEBUG: [WHISPER PROMPT] Updated previous_chunk_transcript_tail (${#previous_chunk_transcript_tail} chars) (first 50): ${previous_chunk_transcript_tail:0:50}..."
        else
            print_error "ERROR: [WHISPER PROMPT] All attempts FAILED for segment $segment_number. Models tried: ${models_to_try[*]}"
            echo "--- [WHISPER PROMPT] Segment $segment_number (FAILED TO TRANSCRIBE) ---" >> "$TRANSCRIPT_TXT_FILE"
            echo "[WHISPER PROMPT] [Transcription failed after trying models: ${models_to_try[*]}]" >> "$TRANSCRIPT_TXT_FILE"
            echo -e "\n" >> "$TRANSCRIPT_TXT_FILE"
            failed_segments=$((failed_segments + 1))
            # If a segment fails, clear the tail so the next segment doesn't get unrelated context
            previous_chunk_transcript_tail=""
        fi
        
        # Clean up the individual .txt file created by Whisper for this segment, as its content is now processed.
        rm -f "${segment_file}.txt"

        # CRITICAL: If all models failed for this segment, abort the entire script.
        if [ "$transcription_successful" == false ]; then
            print_error "CRITICAL ERROR: All Whisper models failed for segment $segment_number ($segment_name). Aborting processing."
            print_error "CRITICAL: All Whisper models failed for segment $segment_number"
            # The EXIT trap will handle general cleanup. Consider if specific additional cleanup for this failure is needed.
            exit 1 # Exit with an error code
        fi

    done # End of segment loop

    # Calculate transcription statistics
    transcription_end_time=$(date +%s)
    transcription_duration=$((transcription_end_time - transcription_start_time))
    total_segments=$((successful_segments + failed_segments))

    # Add transcription statistics to the transcript file
    {
        echo "## Processing Statistics"
        echo "- Total Segments Processed: $total_segments"
        echo "- Successfully Transcribed: $successful_segments"
        echo "- Failed Segments: $failed_segments"
        echo "- Total Processing Time: $transcription_duration seconds"
    } >> "$TRANSCRIPT_TXT_FILE"

    # Clean up temporary whisper directory
    rm -rf "$CURRENT_RUN_DIR/temp_whisper"

    log_info "Stage 3 complete. Transcription saved to: $TRANSCRIPT_TXT_FILE"
    log_info "Successfully transcribed $successful_segments segments ($failed_segments failed) in $transcription_duration seconds"

    print_success "Completed: Audio Processing Workflow"
    # Script will continue with cleanup and final status... (handled by EXIT trap)
}

main "$@" 