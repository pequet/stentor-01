# 030: Stentor Audio Processing Workflow

### 5.1. Overview
The Stentor audio processing workflow is designed to automate the transcription of audio files, from initial acquisition to the final text output. It leverages a combination of client-side scripts for file transfer and a powerful server-side script (`process_audio.sh`) for the core processing tasks.

The general steps are:
1.  **Audio Acquisition (Local Machine):** Use tools like `yt-dlp` on a local machine to download audio. This is recommended to protect the Stentor droplet's IP address.
2.  **Transfer to Stentor (Client-Side):** Securely transfer downloaded audio files to a designated "inbox" directory on the Stentor droplet. The preferred method is using `sshfs` facilitated by client-side scripts (`scripts/client-side/mount_droplet_yt.sh` and `unmount_droplet_yt.sh`). `scp` can be used as an alternative.
3.  **Automated Processing (Stentor Server-Side):**
    *   A **Queue Management System** (to be developed, see section 5.5) will monitor the "inbox" directory for new audio files.
    *   The queue manager will invoke the main processing script, `scripts/audio-processing/process_audio.sh`, for one file at a time.
4.  **Core Processing via `process_audio.sh` (Stentor Server-Side):**
    *   **Input Validation & Standardization:** The script validates the input audio file, creates a unique run directory, and converts the audio to a standard WAV format (16kHz, mono, 16-bit PCM).
    *   **Audio Segmentation:** It analyzes the audio for silences using `ffmpeg` and splits it into smaller, manageable chunks. This is crucial for handling long audio files on resource-constrained systems and improving transcription quality. Details of segmentation are logged in `segmentation_info.md` within the run directory.
    *   **Transcription:** Each audio chunk is transcribed using `whisper.cpp`. The script supports a list of specified Whisper models and includes fallback mechanisms. It employs dynamic timeouts for Whisper execution based on segment duration to optimize performance and prevent stalls.
    *   **Output Generation:** The script generates a detailed Markdown transcript (`audio_transcript.md`) including segment markers and processing statistics, and a clean, concatenated plain text transcript (`audio_transcript.txt`). All outputs for a given audio file are stored within its unique run directory (e.g., `stentor_processing_runs/FILEHASH_TIMESTAMP/`).
5.  **Post-Processing & File Management (Stentor Server-Side):**
    *   The Queue Management System will move the original audio file to "succeeded" or "failed" directories based on the outcome of `process_audio.sh`.
    *   Transcripts are available in the respective run directories.
6.  **Potential AI Post-Processing (Optional):** `vibe-tools` can be used for further analysis or summarization of the generated transcripts if needed.

### 5.2. Audio Transfer Using sshfs (Preferred Method)

`sshfs` is the preferred method for transferring audio files to Stentor, as it allows for direct saving of `yt-dlp` output to the droplet.

#### Prerequisites: Environment Variables

Before proceeding with the steps below, set these environment variables in your local terminal session for use with the commands in this guide:

```bash
export STENTOR_USER="your_chosen_username_here"
export STENTOR_IP="your_droplet_ip_address_here"

# Verify your variables are set
echo "User: $STENTOR_USER" 
echo "Server IP: $STENTOR_IP"
```

#### SSH Key Authentication Setup

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

#### Create Required Directories on the Stentor Droplet

Before using the mount scripts, you need to create the target directory on the Stentor droplet:

```bash
# Connect to your droplet
ssh $STENTOR_USER@$STENTOR_IP

# Create the directory for yt-dlp output
mkdir -p ~/yt_dlp_output

# Create another directory for audio files transferred via scp, if needed
mkdir -p ~/audio_uploads

# Exit the SSH session to return to your local machine
exit
```

#### Mount/Unmount Scripts (Client-Side Utilities)

The `mount_droplet_yt.sh` and `unmount_droplet_yt.sh` scripts for managing `sshfs` connections are located in the `scripts/client-side/` directory of this repository. **These are client-side scripts intended to be run on the local machine (e.g., your laptop or another server) that you are using to connect to and transfer files to the Stentor droplet.** They are not meant to be run on the Stentor droplet itself.

**Important:** Before using these scripts, you must edit them to include your actual server details:

1. **Edit `mount_droplet_yt.sh`:**

```bash
# Open the script in your text editor
nano scripts/client-side/mount_droplet_yt.sh

# Edit these values at the top of the file
REMOTE_USER="your_stentor_user"         # REPLACE with your actual username 
REMOTE_HOST="your_droplet_ip_address"   # REPLACE with your actual droplet IP
```

2. **Make scripts executable:**

```bash
chmod +x scripts/client-side/*.sh
```

3. **Execute the scripts when needed:**

```bash
# To mount the remote directory
./scripts/client-side/mount_droplet_yt.sh

# To unmount when finished
./scripts/client-side/unmount_droplet_yt.sh
```

Example `yt-dlp` command (after mounting on the client machine):

```bash
yt-dlp -x --audio-format mp3 "YOUTUBE_VIDEO_URL_HERE" -o "$HOME/droplet_audio_uploads/%(title)s.%(ext)s"
```

### 5.3. Alternative File Transfer: `scp` Method
For manual, one-off transfers when `sshfs` is not set up or suitable:

```bash
# On local machine, download audio:
yt-dlp -x --audio-format mp3 "YOUTUBE_VIDEO_URL_HERE" -o "%(title)s.%(ext)s"

# Then transfer to Stentor:
scp "Video Title.mp3" $STENTOR_USER@$STENTOR_IP:~/audio_uploads/
```

On Stentor, you'll need an `audio_uploads` directory:

```bash
mkdir -p ~/audio_uploads
```

### 5.4. Core Audio Processing: `process_audio.sh` Script

The primary engine for audio processing on the Stentor droplet is the `scripts/audio-processing/process_audio.sh` script. This script automates the entire pipeline from input audio file to final transcript.

**Key Features:**

*   **Comprehensive Workflow:** Handles input validation, WAV conversion, silence-based segmentation, iterative transcription with multiple Whisper models, dynamic timeouts, and structured output generation.
*   **Robust Input Handling:** Accepts various audio formats (via FFmpeg), sanitizes filenames, and creates a standardized working WAV file.
*   **Intelligent Segmentation:**
    *   Uses `ffmpeg` with the `silencedetect` filter to identify periods of silence based on configurable duration and noise thresholds.
    *   Splits audio into manageable chunks, crucial for long files and resource-limited environments.
    *   Outputs segmentation details to `segmentation_info.md` within each run directory.
    *   Processes the entire file as a single segment if no significant silences are found.
*   **Flexible & Resilient Transcription:**
    *   Utilizes `whisper.cpp` for transcription.
    *   Accepts a comma-separated list of Whisper models (e.g., "tiny.en,base.en") to attempt in sequence.
    *   Includes an ultimate fallback model (default: `tiny.en`) if specified models fail.
    *   Implements **dynamic timeouts** for Whisper execution: the timeout for each segment is calculated based on its duration multiplied by a configurable factor, constrained by minimum and maximum timeout values. This optimizes processing time and prevents indefinite stalls.
    *   If all model attempts fail for a single segment, the script aborts processing for that audio file to prevent cascading errors.
*   **Structured Run Directories:** For each input audio file, a unique directory is created under `stentor_processing_runs/` (e.g., `stentor_processing_runs/MD5HASH_YYYYMMDD_HHMMSS/`). This directory contains all intermediate files and final outputs for that specific run, including:
    *   `audio_workable.wav`: The standardized WAV file used for processing.
    *   `segments/`: A subdirectory containing all individual audio chunks (e.g., `segment_001.wav`, `segment_002.wav`).
    *   `segmentation_info.md`: Details about the segmentation process.
    *   `audio_transcript.md`: A detailed transcript in Markdown format, including segment markers, the Whisper model used for each segment, and overall processing statistics.
    *   `audio_transcript.txt`: A clean, plain text version of the concatenated transcription.
*   **Detailed Logging:** Provides extensive logging throughout its execution, aiding in monitoring and debugging.
*   **Dependency Checking:** Verifies the presence of necessary tools (`ffmpeg`, `ffprobe`, `whisper-cli`, etc.) at startup.

**Script Usage:**

The script is invoked from the command line:

```bash
./scripts/audio-processing/process_audio.sh <input_audio_file_path> [whisper_model_list] [timeout_duration_multiplier]
```

*   `<input_audio_file_path>`: (Required) Path to the input audio file.
*   `[whisper_model_list]`: (Optional) Comma-separated string of Whisper model names to try (e.g., "medium.en,base.en"). Defaults to "tiny.en". Models should be specified without the "ggml-" prefix or ".bin" suffix (e.g., "base.en" not "ggml-base.en.bin").
*   `[timeout_duration_multiplier]`: (Optional) A positive integer used to calculate the dynamic timeout for Whisper processing of each segment (segment duration * multiplier). Defaults to 5.

**Example:**

```bash
./scripts/audio-processing/process_audio.sh "~/audio_uploads/my_podcast.mp3" "base.en,tiny.en" 10
```

**Configuration via Environment Variables (Optional):**

*   `WHISPER_PATH`: Path to the `whisper-cli` (or `main`) executable if not in the default location (`$HOME/src/whisper.cpp/build/bin/whisper-cli`).
*   Other internal script variables like `DEFAULT_WHISPER_MODEL_LIST`, `ULTIMATE_FALLBACK_MODEL`, `MIN_SEGMENT_TIMEOUT_SECONDS`, `MAX_SEGMENT_TIMEOUT_SECONDS`, `SILENCE_DURATION_THRESHOLD`, `SILENCE_NOISE_THRESHOLD` can be modified directly within the script for persistent changes or potentially exposed as environment variables if further flexibility is needed.

**Dependencies:**

*   `ffmpeg` and `ffprobe`: For audio conversion, analysis, and segmentation.
*   `whisper-cli` (or `main` from `whisper.cpp` build): For transcription.
*   Standard Unix utilities: `bc`, `sed`, `date`, `md5sum` (Linux) or `md5` (macOS).

### 5.5. Automated Queue Management Workflow

To enable fully automated, hands-off processing of audio files, a queue management system has been implemented. This system orchestrates the use of `process_audio.sh`.

**Implemented Architecture:**

1.  **Monitored "Inbox" Directory:** A specific directory on the Stentor droplet (`~/stentor_harvesting/inbox/`) is the designated landing zone for incoming audio files.
2.  **Queue Manager Script (`queue_processor.sh`):**
    *   The `scripts/server-side/queue_processor.sh` script manages the entire server-side workflow.
    *   It runs periodically (e.g., via a cron job or inside a `tmux` session).
    *   It implements a robust **lock file mechanism** to ensure only one instance runs at a time.
3.  **Processing Logic:**
    *   The queue manager scans the "inbox" directory for new audio files.
    *   It processes one file at a time, typically the oldest one found.
    *   For the selected file, it invokes `scripts/audio-processing/process_audio.sh`.
    *   It intelligently handles retryable errors (like temporary lock files from `process_audio.sh`) by returning the file to the inbox for a later attempt.
4.  **File Lifecycle Management:**
    *   **On Success:** If `process_audio.sh` succeeds, the queue manager moves the original audio file from the "inbox" to a "succeeded" archive directory and copies the final transcript to the `completed/` directory.
    *   **On Failure:** If `process_audio.sh` fails with a non-recoverable error, the queue manager moves the original audio file to a "failed" directory for manual inspection.
5.  **Logging:** The queue manager maintains its own detailed logs, recording which files are processed, their success/failure status, and any errors encountered.

This automated workflow allows users to simply drop audio files into the "inbox" directory, with the system taking care of the rest.

### 5.6. Performance Testing and Benchmarking

To understand the capabilities and limitations of the Stentor pipeline, the system was subjected to a long-duration endurance test against a real-world backlog of audio content.

**Key Findings:**

*   **Transcription Speed:** The combination of `process_audio.sh`'s segmentation logic and the use of smaller, quantized Whisper models (like `small.en-q5_1` and `base.en-q5_1`) provides a good balance of speed and quality on the resource-constrained 1GB RAM droplet.
*   **Resource Utilization:** The system remains stable under sustained load, with `process_audio.sh` making efficient use of the available CPU and memory for each segment. The swap file provides a necessary safety net against occasional memory spikes.
*   **System Stability:** The robust lock management, error handling, and timeout mechanisms have proven effective at preventing catastrophic failures and ensuring the queue continues to process even when encountering problematic files.

The results of this real-world testing have validated the architecture and provided the confidence needed for the initial public release. Further quantitative benchmarks can be run as needed for specific models or configurations.
