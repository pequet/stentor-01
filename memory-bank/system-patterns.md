---
type: overview
domain: system-state
subject: Stentor
status: active
summary: Documents the recurring technical and workflow patterns for the Stentor project, including environment setup, software components, security standards, and deployment strategies.
---
# System Patterns: Stentor Droplet

## 1. Compute Environment
*   Single DigitalOcean Droplet (or similar VPS).
*   OS: Ubuntu 22.04 LTS (or latest LTS).
*   Initial Specs: 1GB RAM / 1 vCPU / 25GB SSD.
*   Hostname: `Stentor-01`.

## 2. Core Software Components
*   **Whisper.cpp:** For audio transcription.
    *   Models: `tiny.en` and `base.en-q5_1` (recommended for 1GB RAM).
*   **FFmpeg:** Prerequisite for `whisper.cpp` audio handling.
*   **Node.js (v20.x LTS):** For running `vibe-tools`.
*   **Vibe Tools:** For automation and AI interactions.
    *   Requires API key configuration in `~/.vibe-tools/.env`.
*   **Custom Audio Segmentation Script (To be developed):**
    *   Uses `ffmpeg` for silence detection and chunking.
    *   Calls `whisper.cpp` for transcribing chunks.
    *   May implement contextual transcription.

## 3. Security & Access
*   SSH Key authentication is mandatory for server access and `sshfs`.
*   Initial setup as `root`, then switch to a limited sudo user.
*   Environment variables (`STENTOR_USER` and `STENTOR_IP`) are used in documentation for improved copy-paste experience.
*   Firewall (UFW) configured to allow OpenSSH and then enabled.
*   Recommended: Disable password authentication and root login via SSH in `/etc/ssh/sshd_config`.

## 4. Deployment & Workflow Patterns
*   **Environment Variable Setup:** At the beginning of a documentation workflow session, set `STENTOR_USER` and `STENTOR_IP` environment variables in the local terminal for use with documented commands.
*   **Client-Side Script Configuration:** Edit the connection details (username, IP address, paths) directly in the client-side scripts before use.
*   **Audio Acquisition:** `yt-dlp` run on a *local machine or other non-data-center IP* (not the Stentor droplet) to download audio. This is critical to avoid IP blacklisting by services like YouTube.
*   **Audio Transfer to Stentor (Preferred Method):** `sshfs` will be used to temporarily mount a directory from the Stentor droplet onto the acquisition machine.
    *   **Pattern:** Mount before `yt-dlp` operation, save output directly to the mounted path, then unmount immediately after. This minimizes connection issues and enhances scriptability.
    *   **Authentication:** Relies on SSH key-based authentication for passwordless and automatable mounting.
    *   **Scripts:** Client-side scripts in `scripts/client-side/` require editing to insert the actual server details before use.
    *   *(Detailed `sshfs` setup, SSH key generation, and example wrapper scripts for mount/unmount are documented in the `docs/` directory and noted in `tech-context.md`)*.
*   **Audio Transfer to Stentor (Alternative/Basic):** `scp` can be used for manual, one-off transfers to an `audio_uploads` directory on the Stentor droplet if `sshfs` is not set up or suitable for a particular workflow.
*   **Local Project Setup:** `vibe-tools install .` to be run in the local project repository to create `vibe-tools.config.json`.

## 5. Documentation Strategy
*   All setup steps are documented in multiple numbered files in the `docs/` directory for better organization:
    *   `docs/000-stentor-droplet-provisioning-and-initial-setup.md`
    *   `docs/010-installing-nodejs-and-vibe-tools.md`
    *   `docs/020-installing-ffmpeg-and-whisper-cpp.md`
    *   `docs/030-stentor-audio-processing-workflow.md`
    *   `docs/040-stentor-key-decisions-and-learnings.md`
*   `README.md` provides a high-level overview and links to the detailed documentation.
*   Environment variables are used consistently throughout documentation for better usability of command examples.
*   Client-side scripts use hardcoded configuration values that must be edited before use.
*   Key technical decisions and patterns are captured in the Memory Bank files (e.g., `system-patterns.md`, `tech-context.md`).

## 6. Resource Management Considerations (Learnings)
*   `yt-dlp` is run off-droplet (local machine or other non-data-center IP) to protect the Stentor droplet's IP from being flagged/blacklisted.
*   Specific Whisper.cpp models (`tiny.en`, `base.en-q5_1`) are chosen for 1GB RAM viability. Larger models may cause Out Of Memory (OOM) errors.
*   Audio segmentation strategy is necessary for processing longer files with `base.en-q5_1` model (>20 minutes).
*   Resource-intensive `vibe-tools` commands (e.g., `browser`, `repo` on large codebases) may strain 1GB RAM and are not recommended for concurrent use with Whisper.
*   Future scaling might involve a multi-droplet architecture if more services are added or if `vibe-tools` usage becomes heavy. 