#!/bin/bash

# Standard Error Handling
set -e
set -u
set -o pipefail

# Author: Benjamin Pequet
# Purpose: Installs the Stentor client-side utilities, including the harvester and downloader scripts,
#          their configurations, and optional launchd agents for automated execution.
# Project: https://github.com/pequet/stentor-01/

# --- Source Utilities ---
# Resolve the true directory of this install script to find project files
INSTALL_SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${INSTALL_SCRIPT_DIR}/scripts/utils/logging_utils.sh"
source "${INSTALL_SCRIPT_DIR}/scripts/utils/messaging_utils.sh"

# Set a log file path for the installer
LOG_FILE_PATH="${INSTALL_SCRIPT_DIR}/logs/install.log"

# Ensure the installer's log directory exists before any print/log messages
ensure_log_directory

# --- Main Installation Logic ---
main() {
    # --- Argument Parsing ---
    local content_sources_file=""
    local interval_minutes=60 # Default to 60 minutes (hourly)

    # New argument parsing loop
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --interval)
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    interval_minutes="$2"
                    shift # past argument
                    shift # past value
                else
                    print_error "Error: --interval requires a numeric value for minutes."
                    exit 1
                fi
                ;;
            -h|--help)
                print_info "Usage: $0 /path/to/content_sources.txt [--interval <minutes>]"
                print_info "  <content_sources.txt>  Path to the file with URLs."
                print_info "  --interval <minutes>   Optional. Frequency in minutes. Defaults to 60."
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                print_info "Usage: $0 /path/to/content_sources.txt [--interval <minutes>]"
                exit 1
                ;;
            *)
                if [ -z "$content_sources_file" ]; then
                    content_sources_file="$1"
                    shift # past argument
                else
                    print_error "Unexpected argument: $1. Only one content sources file is allowed."
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$content_sources_file" ]; then
        print_error "Usage: $0 /path/to/content_sources.txt [--interval <minutes>]"
        print_info "  <content_sources.txt>  Path to the file with URLs."
        print_info "  --interval <minutes>   Optional. Frequency in minutes. Defaults to 60."
        exit 1
    fi
    
    print_header "Stentor Client-Side Installer"

    # --- Define Paths ---
    # Script paths
    local client_scripts_dir="${INSTALL_SCRIPT_DIR}/scripts/client-side"
    local periodic_script_name="periodic_harvester.sh"
    local dest_dir="/usr/local/bin"

    # Plist paths
    local assets_dir="${INSTALL_SCRIPT_DIR}/assets"
    local periodic_plist_template="com.pequet.stentor.periodic.template.plist"
    local plist_dest_dir="${HOME}/Library/LaunchAgents"
    
    # Derives a clean name for the plist file and for use as a label inside the plist
    local sources_file_basename
    sources_file_basename=$(basename -- "$content_sources_file")
    local sources_file_label="${sources_file_basename%.*}"
    
    local periodic_plist_name="com.pequet.stentor.periodic.${sources_file_label}.plist"
    local periodic_plist_path="${plist_dest_dir}/${periodic_plist_name}"

    # --- Step 1: Verify content sources file ---
    print_step "Step 1: Verifying content sources file"
    if [ ! -f "$content_sources_file" ]; then
        print_error "Content sources file not found at '$content_sources_file'. Please provide a valid path."
        exit 1
    fi
    print_success "Content sources file found: $content_sources_file"


    # --- Step 2: Install Scripts ---
    print_step "Step 2: Installing client-side scripts"
    for script in "$periodic_script_name" "download_to_stentor.sh" "mount_droplet_yt.sh" "unmount_droplet_yt.sh"; do
        local source_path="${client_scripts_dir}/${script}"
        local dest_path="${dest_dir}/${script}"
        if [ ! -f "$source_path" ]; then
            print_error "Source script not found: $source_path"
            exit 1
        fi
        if [ -L "${dest_path}" ] && [ "$(readlink "${dest_path}")" == "${source_path}" ]; then
            print_success "Script '${script}' is already installed and up to date."
        else
            print_info "Installing '${script}' to '${dest_dir}'..."
            sudo ln -sf "$source_path" "$dest_path"
            print_success "  - Installed."
        fi
    done

    # --- Step 3: Install launchd Agents for Automation ---
    print_step "Step 3: Installing Automation Agents (Optional)"
    print_info "This will install a launchd agent to run the periodic harvester automatically for the source file:"
    print_info "  > ${content_sources_file}"
    print_info "  > Frequency: Every ${interval_minutes} minutes."
    read -p "  > Do you want to install this automation agent? (y/N): " -n 1 -r choice
    echo
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        mkdir -p "$plist_dest_dir"

        # Install Periodic Harvester Agent
        print_info "Installing periodic harvester agent for '${sources_file_basename}'..."
        
        # Use a different delimiter for sed since paths contain slashes
        local escaped_sources_path
        escaped_sources_path=$(printf '%s\n' "$content_sources_file" | sed 's:[&/\]:\\&:g')
        
        local interval_seconds=$((interval_minutes * 60))

        local generated_plist_content
        generated_plist_content=$(sed -e "s|{{CONTENT_SOURCES_FILE_PATH}}|${escaped_sources_path}|g" -e "s|{{INTERVAL_IN_SECONDS}}|${interval_seconds}|g" -e "s|{{SOURCES_FILE_LABEL}}|${sources_file_label}|g" "${assets_dir}/${periodic_plist_template}")
        
        echo "${generated_plist_content}" > "${periodic_plist_path}"
        
        print_success "Generated plist file: ${periodic_plist_path}"
        
        launchctl unload "${periodic_plist_path}" >/dev/null 2>&1 || true
        launchctl load "${periodic_plist_path}"
        print_info "Periodic harvester agent for '${sources_file_basename}' installed and loaded."

    else
        print_info "Skipping installation of automation agents."
    fi

    print_separator
    print_completed "Stentor Client-Side Installation Complete"
    print_info "IMPORTANT: Please ensure your stentor.conf file is set up correctly in '~/.stentor/' for remote server settings."
    print_info "TROUBLESHOOTING: If the agent fails with 'Operation not permitted', see the README.md for a one-time fix."
    print_footer
}

# --- Script Entrypoint ---
main "$@" 