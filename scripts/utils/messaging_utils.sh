#!/bin/bash

# Standard Error Handling
# set -e
# set -u
# set -o pipefail
# Note: set -e, -u, -o pipefail are intentionally commented out in this utility
# script to avoid unintentionally altering the error handling behavior of the
# scripts that source it. The calling scripts are responsible for their own
# error handling.

# Author: Benjamin Pequet
# Purpose: Contains utility functions for consistent script messaging.
# Project: https://github.com/pequet/stentor-01/
# Refer to main project for detailed docs.
# Version: 1.0.1 (2025-05-27) - Clarified usage guidance for display_status_message vs. local logging.

# * Usage Guidance
# This script primarily provides the `display_status_message` function.
#
# `display_status_message "<char>" "<message>" [--no-script-name]`
#    - Use for prominent, styled, user-facing status updates directly to the terminal.
#    - Ideal for key script lifecycle events (start, success, failure, important info).
#    - Helps provide a clear, high-level overview of script progress and state to the user.
#    - Automatically includes the calling script's name unless --no-script-name is passed.
#
# Interplay with Local Script Logging (e.g., log_info_local, log_error_local):
#    - Calling scripts (like process_audio.sh, queue_processor.sh) should maintain their own
#      simple, local logging functions (e.g., log_info_local, log_error_local) for detailed,
#      timestamped, potentially file-bound operational logs (debug messages, step-by-step actions).
#    - AVOID REDUNDANCY TO THE TERMINAL: If `display_status_message` is used to announce a key
#      event to the user (e.g., "Processing file X..."), do not *also* use a local log function
#      to print the exact same (or very similar) message to the terminal if that local log also
#      prints to stdout by default. The `display_status_message` is the user-facing highlight.
#    - It IS acceptable for a local log function to write the same event to a dedicated log *file*
#      while `display_status_message` announces it to the terminal. The goal is to prevent
#      cluttering the *terminal* with duplicate information from two different sources.
#
# Example Scenario:
#   display_status_message " " "Starting: File Processing"  # User-facing terminal message
#   log_info_local "File processing initiated for file: $filename" # Detailed log (may go to file and/or stdout)
#   ...
#   display_status_message "x" "Completed: File Processing"
#   log_info_local "File processing finished successfully for file: $filename"

# * Configuration Notes
# Standard Error Handling within this sourced script (set -e, set -u, set -o pipefail)
# is commented out by default. Uncomment with caution, as they can affect the calling script's
# error handling behavior if not managed carefully.
# Consider if errors in this utility should halt the parent script or be handled differently.

# Global variable to be set by the calling script if file logging is desired for that script
# SCRIPT_LOG_FILE="" # This was for a previously considered shared logging system, no longer primary focus.

# * Function Definitions

# ** display_status_message
# Prints a formatted, boxed message to the terminal.
# Usage: display_status_message "<status_char>" "<message_text>"
#   <status_char>: Character to display in brackets (e.g., " ", "x", "!").
#   <message_text>: The message to display.
display_status_message() {
    local status_char="$1"
    local message_text="$2"
    local calling_script_name
    calling_script_name=$(basename "$0") # Get the name of the script that called this function

    # ANSI Color Codes
    local color_reset="\033[0m"
    local color_red="\033[0;31m"
    local color_green="\033[0;32m"
    local color_blue="\033[0;34m"
    local color_cyan="\033[0;36m"
    local color_magenta="\033[0;35m" # For question/prompt

    # ANSI Style Codes
    local style_bold="\033[1m"
    # Note: color_reset (\033[0m) typically resets all attributes, including bold.
    # If specific bold reset is needed, use style_normal="\033[22m".

    local selected_color=""

    # Determine color based on status_char
    case "$status_char" in
        "i") selected_color="$color_blue" ;;
        " ") selected_color="$color_cyan" ;; # Using a space for start, as per rule 265
        "!") selected_color="$color_red" ;;
        "x") selected_color="$color_green" ;;
        "?") selected_color="$color_magenta" ;;
        *) selected_color="$color_reset" ;; # Default to no color if no match
    esac

    # Ensure message_text is not empty, provide a default if it is.
    if [ -z "$message_text" ]; then
        message_text="Status message (no text provided)"
    fi

    local message_line="- [${status_char}] ${message_text} ($calling_script_name)"

    local full_styled_line="${style_bold}${selected_color}${message_line}${color_reset}" 

    printf -- "%b\n" "$full_styled_line"
    return 0 # Ensure the function returns success if printf completes
}

# * Future Development
# Additional messaging or UI utility functions can be added below. 