# Tech Context: Stentor Project

## Core Technologies

### Server Infrastructure
- **DigitalOcean Droplet:** Ubuntu 22.04 LTS, 1GB RAM / 1 vCPU / 25GB SSD ($5-6/month)
- **Server Security:** UFW firewall, SSH key authentication, non-root user with sudo privileges
- **SSH Configuration:** Password authentication and root login disabled for enhanced security

### Audio Transcription
- **Whisper.cpp:** Efficient C++ implementation of OpenAI's Whisper model
  - Models: `tiny.en` (faster) and `base.en-q5_1` (better quality) chosen for 1GB RAM compatibility
  - Larger models (`small.en` or above) will likely cause Out Of Memory errors on 1GB RAM
- **FFmpeg:** Required for audio handling and processing
  - Used both by Whisper.cpp and for silence detection/audio segmentation

### Audio Processing
- **Custom Audio Segmentation Script:** To be developed for chunking audio files
  - Will leverage FFmpeg's silence detection capabilities
  - Will manage sequential transcription of chunks
  - May implement contextual transcription (using previous segment as context)

### AI & Automation
- **Node.js:** LTS (Long-Term Support) version, installed via NodeSource.
- **npm:** Node Package Manager, installed with Node.js and updated to latest.
- **Vibe Tools:** Global installation for AI-powered automation and code generation.
  - Configuration: `~/.vibe-tools/.env` for API keys on the server.
  - Local project config (for development environment): `vibe-tools.config.json` at repository root.

### File Transfer & Management
- **sshfs:** Primary method for audio file transfer to Stentor
  - Relies on SSH key-based authentication
  - Implementation pattern: Mount → Process → Unmount
  - Client-side mount/unmount scripts (`scripts/client-side/mount_droplet_yt.sh`, `scripts/client-side/unmount_droplet_yt.sh`) are part of this codebase and are intended for execution on the machine connecting to Stentor.
- **scp:** Alternative/basic method for one-off transfers

### Audio Acquisition
- **yt-dlp:** Used for downloading audio from sources like YouTube
  - Must be run on local machine/non-data-center IP to avoid blacklisting
  - Output directed to sshfs-mounted directory

## Technical Constraints

1. **Resource Limitations:**
   - 1GB RAM droplet can only handle certain Whisper models reliably
   - Resource-intensive Vibe Tools commands may strain 1GB RAM
   - Concurrent Whisper processing and heavy Vibe Tools usage not recommended

2. **Connectivity Requirements:**
   - SSH access needed for server management and sshfs mounting
   - Stable internet connection for file transfers and remote operations

3. **IP Protection Considerations:**
   - YouTube and similar services may blacklist data center IPs
   - Solution: Run yt-dlp on non-data-center IPs, transfer files to Stentor

## Implementation Notes

### Environment Variables Setup
For ease of use and improved command readability in documentation, set these environment variables in your local terminal session before running documented commands:

```bash
export STENTOR_USER="your_chosen_username_here"
export STENTOR_IP="your_droplet_ip_address_here"

# Verify your variables are set
echo "User: $STENTOR_USER"
echo "Server IP: $STENTOR_IP"
```

These variables are used throughout the documentation for command examples, but note that the client-side scripts have their own hardcoded configuration values.

### SSH Key Authentication Setup
1. **Generate SSH key pair on local machine:**

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

   - An empty passphrase is recommended for scripts/automation
   - Secure the private key file appropriately

2. **Copy public key to Stentor droplet:**

```bash
ssh-copy-id $STENTOR_USER@$STENTOR_IP
```
   
   Alternative manual method:

```bash
# On local machine
cat ~/.ssh/id_ed25519.pub
# Copy output, then on droplet:
mkdir -p ~/.ssh
nano ~/.ssh/authorized_keys
# Paste key, save file
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

### sshfs Mount/Unmount Scripts (Client-Side)
- The `mount_droplet_yt.sh` and `unmount_droplet_yt.sh` scripts are located in the `scripts/client-side/` directory of this repository.
- **These are client-side scripts, designed to be run on the machine initiating the `sshfs` connection to the Stentor droplet (e.g., your local computer or another server performing audio acquisition).**
- Before using these scripts, you must edit them to include your actual server connection details (username, IP address).
- These scripts facilitate the mounting and unmounting of the Stentor droplet's audio directory via `sshfs`.
- Ensure they are executable on the client machine (`chmod +x scripts/client-side/*.sh`).

## Future Technical Considerations
- If system grows to include more services or resource needs increase, consider multi-droplet architecture
- Web frontend/API could be deployed on a separate droplet
- Heavy Vibe Tools usage might justify its own dedicated droplet 