# 000: Stentor Droplet - Provisioning & Initial Setup

This section outlines the steps for provisioning a new DigitalOcean droplet (or similar VPS) for the Stentor project.

### 3.1. Droplet Specifications

#### OS Choice: Ubuntu 24.04 LTS
Ubuntu 24.04 LTS is selected for: stability, 5-year long-term support, excellent software availability for our stack, strong community support, good balance of updated packages with stability.

#### CPU/Droplet Plan: Premium AMD with NVMe SSD
*   **Provider:** DigitalOcean (or preferred VPS provider).
*   **Image:** Ubuntu 24.04 LTS.
*   **Plan:** Premium AMD CPU with NVMe SSD (1GB RAM, 1 vCPU).
    *   **Rationale:** Premium CPU significantly improves Whisper.cpp transcription speed; NVMe SSD accelerates model/audio loading and file segmentation workflow (MP3→WAV conversion, silence detection, and file splitting); cost-effective for performance gained.
*   **Scaling:** Can double RAM to 2GB and scale to 2 CPUs within same architecture if needed.
*   **Datacenter Region:** Choose one geographically close for lower latency.
*   **Authentication:** **SSH Key** authentication is mandatory.
*   **Hostname:** `Stentor-01`

### 3.2. Initial Server Hardening
**(As `root` initially, then switch to a limited user)**

**Important: Set Environment Variables**

Before proceeding, set the following environment variables in your **local terminal session**. Replace the placeholder values with your actual chosen username and droplet's IP address:

```bash
export STENTOR_USER="your_chosen_username_here"
export STENTOR_IP="your_droplet_ip_address_here"

# Verify your variables are set
echo "User: $STENTOR_USER"
echo "Server IP: $STENTOR_IP"
```

These variables will be used in all commands, allowing you to copy and paste them directly.

1.  **First Login (as `root`):**

```bash
ssh root@$STENTOR_IP
```

2.  **Create a Limited User Account:**

```bash
# Create new user
adduser $STENTOR_USER

# Add user to sudo group
usermod -aG sudo $STENTOR_USER

# Log out from root
exit

# Log in as your new user
ssh $STENTOR_USER@$STENTOR_IP
```

2.1. **Configure SSH Key Authentication for New User (Highly Recommended):**
    *   This step enables passwordless SSH and SFTP access, which is more secure and convenient for both manual and automated tasks like `sshfs`.
    *   The actions involve your **LOCAL machine** and the **SERVER (Stentor-01)**.

    **On your LOCAL machine:**
    1.  If you don't have an SSH key, generate one (Ed25519 is preferred):

```bash
# This command creates a new key pair. Accept defaults when prompted.
# Replace the comment with a meaningful identifier.
ssh-keygen -t ed25519 -C "your_username@your_machine_name"
```

    2.  **Copy your public key to the server (Recommended Method):**
        The `ssh-copy-id` utility is the simplest and safest way to install your public key on the server. It handles directory creation and permissions automatically.

```bash
ssh-copy-id $STENTOR_USER@$STENTOR_IP
```

        *   You will be prompted for your user's password on the server one last time.
        *   After this completes, you can skip to the "Verification" step below.

    **On your LOCAL machine (Manual Fallback Method):**
    *   If `ssh-copy-id` is not available, you can add the key manually.
    1.  Display and copy your **public** key to the clipboard:

```bash
cat ~/.ssh/id_ed25519.pub
```
    2.  Log into the server with your password: `ssh $STENTOR_USER@$STENTOR_IP`
    3.  Once on the server, run these commands:

```bash
# On the SERVER (Stentor-01 droplet)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "PASTE_YOUR_COPIED_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
exit
```

    **On your LOCAL machine (Verification):**
    1.  Attempt to SSH into the server again. It should now log you in without a password.

```bash
ssh $STENTOR_USER@$STENTOR_IP
```

    *From this point, all commands should be run as `$STENTOR_USER`, using `sudo` where necessary.*

3.  **Configure Firewall (UFW):**
    *   Immediately hardens the server by blocking all non-essential incoming traffic (default deny).
    *   `allow OpenSSH` is crucial to maintain access; UFW is then enabled.

```bash
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status verbose
```

4.  **Update System Packages:**

```bash
sudo apt update && sudo apt upgrade -y
```

5.  **Install Essential Build Tools:**

```bash
sudo apt install -y build-essential git pkg-config cmake
```

6.  **Transfer Setup Scripts to Server (via SFTP):**
    *   Use the SFTP extension in your Cursor IDE (or any SFTP client) to connect to your Stentor droplet as the `$STENTOR_USER`.
    *   Create a directory on the server to hold these setup scripts, for example, `~/stentor-01`.
    *   Upload the `scripts/server-setup/configure-swap.sh` file from your local project to `~/stentor-01/scripts/server-setup/` on the droplet. You may choose to upload the entire local `scripts` directory if you anticipate needing other scripts.

7.  **Configure Swap Space:**
    *   This script configures a 2GB swap file, crucial for stability on 1GB RAM systems.
    *   It acts as a safety net against Out-Of-Memory crashes.
    *   It is not a replacement for adequate physical RAM if consistently exceeded.

```bash
# Navigate to the directory where you uploaded the scripts
cd ~/stentor-01/scripts/server-setup/

# Make the script executable
sudo chmod +x configure-swap.sh

# Run the swap configuration script
sudo ./configure-swap.sh
```

8.  **Secure SSH (Disable Direct Root Login - Recommended):**
    *   **Goal:** Disable direct SSH login for the `root` user, forcing administrative access through your limited user (`$STENTOR_USER`) and `sudo`.
    *   **Note:** This change will still allow `$STENTOR_USER` to log in via SSH using their password AND/OR their SSH key.
    *   **Action (on server, as `$STENTOR_USER`):** Edit `/etc/ssh/sshd_config` (e.g., `sudo nano /etc/ssh/sshd_config`).
        *   Ensure `PermitRootLogin no` (uncomment if needed and set to `no`).
        *   Ensure `PasswordAuthentication yes` (this is typically the default; confirm it is not set to `no`).
    *   Save changes (in `nano`: `Ctrl+O`, `Enter`, `Ctrl+X`).
    *   Then, restart the SSH service:

```bash
sudo systemctl restart ssh.service
sudo systemctl status ssh.service
```

    *   This change specifically disables direct root SSH login. `$STENTOR_USER` can still log in with their password.

### 3.3. Optional: Install DigitalOcean Metrics Agent

DigitalOcean offers a lightweight metrics agent (`do-agent`) that provides basic server monitoring (CPU, RAM, Disk I/O, Network). This can be useful for observing resource utilization, especially when testing Whisper.cpp performance. It can be enabled/disabled via the DigitalOcean control panel after installation and uninstalled if no longer needed.

*Consider using a more comprehensive tool like New Relic if you manage multiple servers or need detailed application performance monitoring, but be mindful of its higher resource usage, especially on 1GB RAM droplets. It might be more suitable if/when scaling to a larger droplet (e.g., 2GB+ RAM).*

**To install the `do-agent`:**

```bash
curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo bash
```

**To check status or (re)start (usually starts automatically after install):**

```bash
sudo systemctl status do-agent
sudo systemctl restart do-agent
```

**To uninstall the `do-agent` completely (purge configuration files):**

```bash
sudo apt purge do-agent -y
```