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
    print_header "Stentor Client-Side Installer"

    # --- Define Paths ---
    # Script paths
    local client_scripts_dir="${INSTALL_SCRIPT_DIR}/scripts/client-side"
    local harvester_script_name="harvest_webpage_links.sh"
    local periodic_script_name="periodic_harvester.sh"
    local dest_dir="/usr/local/bin"

    # Plist paths
    local assets_dir="${INSTALL_SCRIPT_DIR}/assets"
    local harvester_plist_template="com.pequet.stentor.harvester.template.plist"
    local periodic_plist_template="com.pequet.stentor.periodic.template.plist"
    local plist_dest_dir="${HOME}/Library/LaunchAgents"

    # --- Step 1: Install Scripts ---
    print_step "Step 1: Installing client-side scripts"
    for script in "$harvester_script_name" "$periodic_script_name" "download_to_stentor.sh" "mount_droplet_yt.sh" "unmount_droplet_yt.sh"; do
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

    # --- Step 2: Install launchd Agents for Automation ---
    print_step "Step 2: Installing Automation Agents (Optional)"
    read -p "  > Do you want to install automation agents? (y/N): " -n 1 -r choice
    echo
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        mkdir -p "$plist_dest_dir"

        # Install Harvester Agent
        local harvester_plist_name="com.pequet.stentor.harvester.plist"
        local harvester_plist_path="${plist_dest_dir}/${harvester_plist_name}"
        print_info "Installing harvester agent..."
        cp "${assets_dir}/${harvester_plist_template}" "${harvester_plist_path}"
        launchctl unload "${harvester_plist_path}" >/dev/null 2>&1 || true
        launchctl load "${harvester_plist_path}"
        print_success "  - Harvester agent installed and loaded."

        # Install Periodic Harvester Agent
        local periodic_plist_name="com.pequet.stentor.periodic.plist"
        local periodic_plist_path="${plist_dest_dir}/${periodic_plist_name}"
        print_info "Installing periodic harvester agent..."
        cp "${assets_dir}/${periodic_plist_template}" "${periodic_plist_path}"
        launchctl unload "${periodic_plist_path}" >/dev/null 2>&1 || true
        launchctl load "${periodic_plist_path}"
        print_success "  - Periodic harvester agent installed and loaded."

    else
        print_info "Skipping installation of automation agents."
    fi

    print_separator
    print_completed "Stentor Client-Side Installation Complete"
    print_info "IMPORTANT: Please ensure your configuration files are set up correctly in the '~/.stentor/' directory."
    print_info "This includes 'target_webpage_url.txt', 'content_sources.txt', and 'stentor.conf' for remote server settings."
    print_footer
}

# --- Script Entrypoint ---
main "$@" 