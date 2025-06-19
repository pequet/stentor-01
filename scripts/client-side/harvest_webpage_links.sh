#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# ██ ██   Stentor: Harvest YouTube Links from URLs
# █ ███   Version: 1.2.1
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Scrapes one or more configured webpages for YouTube video links using the
#   Browser MCP server and prepends any new links to the main content sources list.
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
#   ./harvest_webpage_links.sh
#
# Dependencies:
#   - mcp: The command-line MCP client (mcptools).
#   - npx: To run the browsermcp server.
#   - jq: For parsing JSON output from the browser snapshot.
#   - Standard Unix utilities: grep, sed, sort, head, cat, mv.

# * Configuration
CONFIG_FILE="$HOME/.stentor/target_webpage_url.txt"
CONTENT_SOURCES_FILE="$HOME/.stentor/content_sources.txt"
LOCK_FILE="$HOME/.stentor/harvest_webpage_links.lock"
LOCK_ACQUIRED_BY_THIS_PROCESS=false

# * Logging Functions
log_info() { echo "INFO: $1"; }
log_warn() { echo "WARN: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }

# * Lock Management
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log_error "Lock file exists at $LOCK_FILE. Another instance may be running."
        return 1
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED_BY_THIS_PROCESS=true
    log_info "Lock file created."
}

# * Cleanup Function
cleanup() {
    log_info "Script finished. Cleaning up..."
    if [ ! -z "${MCP_SERVER_PID-}" ]; then
        # Kill the process silently. The '|| true' prevents errors if it's already gone.
        kill "$MCP_SERVER_PID" 2>/dev/null || true
        log_info "Background MCP server (PID: $MCP_SERVER_PID) terminated."
    fi
    if [ "$LOCK_ACQUIRED_BY_THIS_PROCESS" = "true" ]; then
        rm -f "$LOCK_FILE"
        log_info "Lock file removed."
    fi
}

# * Link Processing Functions
update_content_sources() {
    local new_links="$1"
    if [ -z "$new_links" ]; then
        log_info "No new links to add."
        return
    fi

    log_info "Adding new links to $CONTENT_SOURCES_FILE..."
    
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
    log_info "$(echo "$new_links" | wc -l | xargs) new links have been added to the top of the file."
}

# * Main Logic
main() {
    log_info "Starting script."
    trap cleanup EXIT INT TERM HUP

    if ! acquire_lock; then
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found at $CONFIG_FILE"
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
        log_warn "No valid URLs found in $CONFIG_FILE. Exiting."
        exit 0
    fi

    log_info "Found $num_urls target URLs to process."

    log_info "Starting MCP Browser server in the background..."
    npx @conradkoh/browsermcp@latest &
    MCP_SERVER_PID=$!
    sleep 3 # Give server time to initialize
    log_info "MCP server started with PID: $MCP_SERVER_PID"

    local all_found_links=""
    
    for i in "${!URL_ARRAY[@]}"; do
        local TARGET_URL="${URL_ARRAY[$i]}"
        local current_index=$((i + 1))

        log_info "-------------------------------------------"
        log_info "Processing URL $current_index of $num_urls: $TARGET_URL"
        
        log_info "Navigating to target URL..."
        if ! mcp call browser_navigate --params "{\"url\": \"$TARGET_URL\"}" npx @conradkoh/browsermcp@latest > /dev/null; then
            log_error "Failed to navigate to the target URL: $TARGET_URL. Skipping."
            continue
        fi
        log_info "Navigation successful."

        local waits=(2 4 8 16)
        local links_found_for_url=false
        local current_url_links=""

        for wait_time in "${waits[@]}"; do
            log_info "Waiting ${wait_time}s for page content to load..."
            sleep "$wait_time"
            
            log_info "Taking page snapshot and processing for YouTube links..."
            current_url_links=$(mcp call browser_snapshot --format json npx @conradkoh/browsermcp@latest | \
                jq -r '.content[0].text' | \
                grep -o -E 'https://www.youtube.com/embed/[a-zA-Z0-9_-]+|https://youtu.be/[a-zA-Z0-9_-]+' | \
                sed 's/embed\//watch?v=/' | \
                sed 's|https://youtu.be/|https://www.youtube.com/watch?v=|' | \
                sort -u || true)
            
            if [ -n "$current_url_links" ]; then
                log_info "Found links for this URL. Proceeding..."
                links_found_for_url=true
                break
            else
                log_warn "No links found for this URL after ${wait_time}s wait. Trying next interval."
            fi
        done

        if [ "$links_found_for_url" = true ]; then
             all_found_links=$(echo -e "${all_found_links}\n${current_url_links}" | sed '/^$/d' | sort -u)
        else
            log_warn "No YouTube links were found on $TARGET_URL after all wait intervals."
        fi

        # Pause only if this is not the last URL
        if [ "$current_index" -lt "$num_urls" ]; then
            log_info "Pausing for 5 seconds before processing the next URL..."
            sleep 5
        fi
    done

    if [ -z "$all_found_links" ]; then
        log_info "No links found across any of the provided URLs."
        exit 0
    fi
    
    log_info "-------------------------------------------"
    log_info "Comparing all found links with existing links in $CONTENT_SOURCES_FILE..."
    local existing_links=""
    if [ -f "$CONTENT_SOURCES_FILE" ]; then
        existing_links=$(cat "$CONTENT_SOURCES_FILE")
    fi

    local new_links
    new_links=$(echo "$all_found_links" | grep -v -F -x -f <(echo "$existing_links") || true)

    if [ -z "$new_links" ]; then
        log_info "All found links are already present in the content sources file."
    else
        echo
        log_info "Found the following new YouTube links across all pages:"
        echo "-------------------------------------------"
        echo "$new_links"
        echo "-------------------------------------------"
        update_content_sources "$new_links"
    fi
}

# Run main function
main 