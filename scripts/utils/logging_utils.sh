#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Logging Utilities
# Version: 1.1.0
# Author: Benjamin Pequet
# Projects: https://github.com/pequet/ 
# Purpose: Provides file-based logging utility functions.
# Refer to main project for detailed docs.

# Changelog:
# 1.2.0: Added wrapper functions for compatibility.
# 1.1.0: Added logging control functions.
# 1.0.0: Initial release.

# --- Guard against direct execution ---
# This script provides utility functions and is not meant to be executed directly.
# It should be sourced by other DLS scripts.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script provides utility functions and is not meant to be executed directly." >&2
    echo "Please source it from another DLS script." >&2
    exit 1
fi

# --- Global Configuration ---
# Set LOGGING_ENABLED=0 to disable all logging
# Set LOG_FILE_PATH to change where logs go (e.g., RAM disk, /dev/null, etc.)
LOGGING_ENABLED=${LOGGING_ENABLED:-1}  # Default: enabled

# --- Function Definitions ---

# *
# * Logging Functions
# *
# Handles all file-based logging operations.
# Expects the calling script to define:
#   - LOG_FILE_PATH: The full path to the log file.
# Optional:
#   - LOGGING_ENABLED: Set to 0 to disable logging, 1 to enable (default: 1)

# Ensures the log directory exists
ensure_log_directory() {
    local log_dir
    log_dir=$(dirname "${LOG_FILE_PATH}")
    if ! mkdir -p "${log_dir}"; then
        # This is a fatal error before logging is even possible. Echo directly.
        echo "FATAL: Cannot create log directory: ${log_dir}" >&2
        exit 1
    fi
}

# Logs a message to the log file
log_message() {
    # If logging is disabled, do nothing
    if [[ "${LOGGING_ENABLED:-1}" -eq 0 ]]; then
        return 0
    fi
    
    local type="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$(hostname)] [${type}] ${message}" >> "${LOG_FILE_PATH}"
}

# --- Wrapper Functions for compatibility ---
log_info() {
    log_message "INFO" "$1"
}

log_warning() {
    log_message "WARNING" "$1"
}

log_error() {
    log_message "ERROR" "$1"
}

log_debug() {
    # For now, aliasing log_debug to log_info.
    # A more advanced implementation could check a DEBUG_MODE flag.
    log_message "DEBUG" "$1"
}

# *
# * Logging Control Functions (v1.1.0)
# *

# Disables all logging
disable_logging() {
    LOGGING_ENABLED=0
}

# Enables logging
enable_logging() {
    LOGGING_ENABLED=1
} 