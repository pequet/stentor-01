#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Harvest YouTube Links from URLs
# █ ███   Version: 1.1.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Scrapes one or more configured webpages for YouTube video links using the
#   Browser MCP server and prepends any new links to the main content sources list.
#   Documentation: https://docs.browsermcp.io/welcome
#
# Features:
#   - Reads one or more target URLs from a configuration file (ignoring comments and blank lines).
#   - Manages its own Browser MCP server instance, starting and stopping it automatically.
#   - Ensures only one instance of the script runs at a time using a lock file.
#   - Uses an exponential backoff wait to handle dynamic page content loading for each URL.
#   - Pauses between processing each URL, but only if there are more to process.
#   - Compares found links against the existing content sources list and only adds new ones in a single batch.
#
# Usage:
#   ./harvest_webpage_links.sh <content_sources_file>
#
# Arguments:
#   content_sources_file: The path to the file where new YouTube links will be prepended.
#
# Dependencies:
#   - mcp: The command-line MCP client. Installed via Homebrew from a custom tap:
#          `brew tap f/mcptools && brew install mcp`
#   - npx: To run the browsermcp server. Part of Node.js. Install with `brew install node`.
#   - jq: For parsing JSON output. Install with `brew install jq`.
#   - Standard Unix utilities: grep, sed, sort, head, cat, mv.
#
# Change Log:
#   1.1.0 - 2025-07-29 - Added support for message and logging utilities, dependency checking, and argument handling.
#   1.0.0 - 2025-06-19 - Initial release.

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
LOG_FILE_PATH="$HOME/.stentor/logs/harvest_webpage_links.log"

# * Dependency Check
if ! command -v mcp &> /dev/null; then
    print_error "Dependency 'mcp' is not installed."
    echo "Please install it by first tapping the repository and then installing:"
    echo "brew tap f/mcptools && brew install mcp"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    print_error "Dependency 'jq' is not installed."
    echo "Please install it. On macOS, you can use Homebrew:"
    echo "brew install jq"
    exit 1
fi

if ! command -v npx &> /dev/null; then
    print_error "Dependency 'npx' is not installed. It is part of Node.js."
    echo "Please install Node.js (which includes npx)."
    echo "On macOS with Homebrew, you can run:"
    echo "brew install node"
    exit 1
fi

# * Configuration
CONFIG_FILE="$HOME/.stentor/target_webpage_url.txt"
LOCK_FILE="$HOME/.stentor/harvest_webpage_links.lock"
LOCK_ACQUIRED_BY_THIS_PROCESS=false

# * Lock Management
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        print_error "Lock file exists at $LOCK_FILE. Another instance may be running."
        return 1
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED_BY_THIS_PROCESS=true
    print_info "Lock file created."
}

# * Cleanup Function
cleanup() {
    print_info "Script finished. Cleaning up..."
    if [ ! -z "${MCP_SERVER_PID-}" ]; then
        # Kill the process silently. The '|| true' prevents errors if it's already gone.
        kill "$MCP_SERVER_PID" 2>/dev/null || true
        print_info "Background MCP server (PID: $MCP_SERVER_PID) terminated."
    fi
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        rm -f "$LOCK_FILE"
        print_info "Lock file removed."
    fi
}

# * Link Processing Functions
update_content_sources() {
    local new_links="$1"
    if [ -z "$new_links" ]; then
        print_info "No new links to add."
        return
    fi

    print_info "Adding new links to $CONTENT_SOURCES_FILE..."
    
    # Create a temporary file
    local temp_file
    temp_file=$(mktemp)

    # Write new links to the temporary file
    echo "$new_links" > "$temp_file"
    
    # Append the existing content (if the file exists) to the temporary file
    if [ -f "$CONTENT_SOURCES_FILE" ]; then
        cat "$CONTENT_SOURCES_FILE" >> "$temp_file"
    fi

    # Replace the original file with the updated one
    mv "$temp_file" "$CONTENT_SOURCES_FILE"
    print_info "$(echo "$new_links" | wc -l | xargs) new links have been added to the top of the file."
}

# * Main Logic
main() {
    if [ "$#" -ne 1 ]; then
        print_error "Missing mandatory argument."
        echo "Usage: $0 <content_sources_file>"
        echo "  <content_sources_file>: Path to the file where new YouTube links will be prepended."
        exit 1
    fi
    CONTENT_SOURCES_FILE="$1"

    print_info "Starting script."
    trap cleanup EXIT INT TERM HUP

    if ! acquire_lock; then
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found at $CONFIG_FILE"
        exit 1
    fi

    # Read all non-empty, non-comment lines into an array in a portable way
    URL_ARRAY=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        URL_ARRAY+=("$line")
    done < <(grep -v -e '^$' -e '^#' "$CONFIG_FILE")
    local num_urls=${#URL_ARRAY[@]}

    if [ "$num_urls" -eq 0 ]; then
        print_warning "No valid URLs found in $CONFIG_FILE. Exiting."
        exit 0
    fi

    print_info "Found $num_urls target URLs to process."

    print_info "Starting MCP Browser server in the background..."
    npx @conradkoh/browsermcp@latest &
    MCP_SERVER_PID=$!
    sleep 3 # Give server time to initialize
    print_info "MCP server started with PID: $MCP_SERVER_PID"

    local all_found_links=""
    
    for i in "${!URL_ARRAY[@]}"; do
        local TARGET_URL="${URL_ARRAY[$i]}"
        local current_index=$((i + 1))

        print_info "-------------------------------------------"
        print_info "Processing URL $current_index of $num_urls: $TARGET_URL"
        
        print_info "Navigating to target URL..."
        if ! mcp call browser_navigate --params "{\"url\": \"$TARGET_URL\"}" npx @conradkoh/browsermcp@latest > /dev/null; then
            print_error "Failed to navigate to the target URL: $TARGET_URL. Skipping."
            continue
        fi
        print_info "Navigation successful."

        local waits=(2 4 8 16)
        local links_found_for_url=false
        local current_url_links=""

        for wait_time in "${waits[@]}"; do
            print_info "Waiting ${wait_time}s for page content to load..."
            sleep "$wait_time"
            
            print_info "Taking page snapshot and processing for YouTube links..."
            current_url_links=$(mcp call browser_snapshot --format json npx @conradkoh/browsermcp@latest | \
                jq -r '.content[0].text' | \
                grep -o -E 'https://www.youtube.com/embed/[a-zA-Z0-9_-]+|https://youtu.be/[a-zA-Z0-9_-]+' | \
                sed 's/embed\//watch?v=/' | \
                sed 's|https://youtu.be/|https://www.youtube.com/watch?v=|' | \
                sort -u || true)
            
            if [ -n "$current_url_links" ]; then
                print_info "Found links for this URL. Proceeding..."
                links_found_for_url=true
                break
            else
                print_warning "No links found for this URL after ${wait_time}s wait. Trying next interval."
            fi
        done

        if [ "$links_found_for_url" = true ]; then
             all_found_links=$(echo -e "${all_found_links}\n${current_url_links}" | sed '/^$/d' | sort -u)
        else
            print_warning "No YouTube links were found on $TARGET_URL after all wait intervals."
        fi

        # Pause only if this is not the last URL
        if [ "$current_index" -lt "$num_urls" ]; then
            print_info "Pausing for 5 seconds before processing the next URL..."
            sleep 5
        fi
    done

    if [ -z "$all_found_links" ]; then
        print_info "No links found across any of the provided URLs."
        exit 0
    fi
    
    print_info "Comparing all found links with existing links in $CONTENT_SOURCES_FILE..."
    local existing_links=""
    if [ -f "$CONTENT_SOURCES_FILE" ]; then
        existing_links=$(cat "$CONTENT_SOURCES_FILE")
    fi

    local new_links
    new_links=$(echo "$all_found_links" | grep -v -F -x -f <(echo "$existing_links") || true)

    if [ -z "$new_links" ]; then
        print_info "All found links are already present in the content sources file."
    else
        echo
        print_info "Found the following new YouTube links across all pages:"
        print_separator_line
        print_info "$new_links"
        print_separator_line
        update_content_sources "$new_links"
    fi
}

# Run main function
main "$@" 