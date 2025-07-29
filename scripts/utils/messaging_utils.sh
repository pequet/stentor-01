#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Messaging Utilities
# Version: 1.2.0
# Author: Benjamin Pequet
# Projects: https://github.com/pequet/
# Purpose: Provides terminal messaging utility functions.

# Changelog:
# 1.2.0: Added the function `display_status_message` for backward compatibility with previous scripts.
# 1.1.1: Moved `prompt_user_input` to a new `input_utils.sh` as it's an input function.
# 1.1.0: Added a new function `prompt_user_input` to prompt the user for input with a default value.
# 1.0.0: Initial release.

# --- Guard against direct execution ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script provides utility functions and is not meant to be executed directly." >&2
    echo "Please source it from another DLS script." >&2
    exit 1
fi

# --- Function Definitions ---

# *
# * Messaging Functions
# *
# Handles all terminal/console output.
# Expects logging_utils.sh to be sourced first.

print_header() {
    local title="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "$title ($calling_script_name)"
    print_separator
    log_message "INFO" "--- Script Start: $title ---"
}

print_separator() {
    echo "========================================================================"
}

print_separator_line() {
    echo "------------------------------------------------------------------------"
}

print_footer() {
    print_separator
    log_message "INFO" "--- Script End ---"
}

print_step() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "- ${message} ($calling_script_name)"
    log_message "STEP" "${message} ($calling_script_name)"
}

print_completed() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "🏁 ${message} ($calling_script_name)"
    log_message "COMPLETED" "${message} ($calling_script_name)"
}

print_info() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "${message} ($calling_script_name)"
    log_info "${message} ($calling_script_name)"
}

print_success() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "- [x] SUCCESS: ${message} ($calling_script_name)"
    log_message "SUCCESS" "${message} ($calling_script_name)"
}

print_warning() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "- [!] WARNING: ${message} ($calling_script_name)"
    log_warning "${message} ($calling_script_name)"
}

print_error() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "- [!] ERROR: ${message} ($calling_script_name)" >&2
    log_error "${message} ($calling_script_name)"
}

print_error_details() {
    local command="$1"
    local output="$2"
    local details="Details: Command Failed: \`${command}\`"
    echo "    ${details}" >&2
    echo "    Output:" >&2
    echo "${output}" | awk '{print "      " $0}' >&2
    log_error "${details}"
    log_error "Output: ${output}"
}

print_question() {
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "- [?] QUESTION: ${message} ($calling_script_name)"
    log_message "QUESTION" "${message} ($calling_script_name)"
}

print_debug() {
    # For now, aliasing log_debug to log_info.
    # A more advanced implementation could check a DEBUG_MODE flag.
    local message="$1"
    local calling_script_name
    calling_script_name=$(basename "$0")
    echo "🚧 DEBUG: ${message} ($calling_script_name)"
    log_debug "${message} ($calling_script_name)"
}

# Formats a status line with an action, subject, and result.
# E.g., print_status_line "[COPYING]" "file.txt" "SUCCESS"
print_status_line() {
    local action="$1"
    local subject="$2"
    local result="$3"
    
    # Pad the subject to align the result column
    printf "%-14s %-45s ... %s\n" "${action}" "${subject}" "${result}"
    
    if [[ "${result}" != "SUCCESS" && "${result}" != *"SKIPPED"* ]]; then
        log_error "Action '${action}' on '${subject}' resulted in: ${result}"
    else
        log_info "Action '${action}' on '${subject}' resulted in: ${result}"
    fi
} 

# *
# * Backward-Compatibility Wrapper (Phased-Out Function)
# *

# ** display_status_message
# Kept for backward compatibility with older scripts.
# It wraps the new, more descriptive print_* functions.
display_status_message() {
    local status_char="$1"
    local message_text="$2"

    case "$status_char" in
        "i") print_info "${message_text}" ;;
        " ") print_step "${message_text}" ;;
        "!") print_error "${message_text}" ;;
        "x") print_success "${message_text}" ;;
        "?") print_question "${message_text}" ;;
        *)   print_info "${message_text}" ;; # Default to a standard step
    esac
} 