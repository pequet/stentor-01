# 020: Installing FFmpeg and Whisper.cpp on Stentor

This document covers the installation of FFmpeg and Whisper.cpp on the Stentor-01 server (Ubuntu 24.04 LTS), enabling audio transcription capabilities.

**Prerequisites:**
*   The server has been provisioned and hardened as per `docs/000-stentor-droplet-provisioning-and-initial-setup.md`.
*   You are logged into the Stentor-01 server as the limited user (`$STENTOR_USER`) with `sudo` privileges.
*   The `$STENTOR_USER` and `$STENTOR_IP` environment variables are assumed to be set in your local environment if you are copying commands that might use them.

## 1. Automated Installation using Script (Recommended)

A script has been provided to automate the download, compilation, and initial setup of Whisper.cpp, including downloading a default model (`tiny.en`) and listing other available models.

**Steps to use the script:**

1.  **Ensure the script is on your server:**
    If you haven't already, transfer the `scripts/server-setup/install-whisper-cpp.sh` file from your local project to your Stentor-01 server. A good location would be `~/stentor-01/scripts/server-setup/` (consistent with other setup scripts).
    You can use SFTP for this, as outlined in `docs/000-stentor-droplet-provisioning-and-initial-setup.md` (Step 6).

2.  **Make the script executable:**

```bash
chmod +x ~/stentor-01/scripts/server-setup/install-whisper-cpp.sh
```

3.  **Run the script:**

```bash
~/stentor-01/scripts/server-setup/install-whisper-cpp.sh
```
    The script will:
    *   Install necessary system dependencies (including FFmpeg).
    *   Clone the Whisper.cpp repository to `~/src/whisper.cpp` (or update it if it exists).
    *   Compile Whisper.cpp.
    *   Download the `tiny.en` model to `~/src/whisper.cpp/models/`.
    *   List all other available models for you to download manually if desired.

4.  **Review Output and Download Additional Models (Optional):**
    After the script completes, it will list available models. If you wish to download a different or larger model (e.g., a quantized version of `base.en` or `small.en`), you can do so by navigating to the models directory and using the download script:

```bash
cd ~/src/whisper.cpp/models
bash ./download-ggml-model.sh <your_chosen_model_name>
# Example: bash ./download-ggml-model.sh base.en-q5_1
```

## 2. Testing Transcription

The installation script (`install-whisper-cpp.sh`) already performs an initial compilation and downloads a default model. It also provides example commands to run a transcription.

To test with a specific model and audio file:

1.  **Navigate to the Whisper.cpp directory:**

```bash
cd ~/src/whisper.cpp
```

2.  **Ensure you have an audio file.** The `samples` directory within `whisper.cpp` usually contains `jfk.wav`. If not, you can upload your own.

3.  **Run a Transcription:**
    Use the `./build/bin/main` executable. You'll need to specify:
    *   `-m <model_path>`: Path to the downloaded model file (e.g., `models/ggml-tiny.en.bin`).
    *   `-f <audio_file_path>`: Path to the audio file you want to transcribe (e.g., `samples/jfk.wav`).
    *   (Optional) `-l <language>`: Specify the language (e.g., `en` for English).
    *   (Optional) `-otxt`: Output transcription to a `.txt` file.

    **Example:**

```bash
./build/bin/main -m models/ggml-base.en.bin -f samples/jfk.wav -l en -otxt
```

4.  **Check the Output:**
    The transcription will be printed to the console. If you used `-otxt`, a file like `jfk.wav.txt` will be created in the current directory.

```bash
cat samples/jfk.wav.txt
```

*Note on Performance: The first run with a model might be slightly slower. This is primarily because the model file (e.g., `ggml-base.en.bin`) must be loaded from storage (NVMe SSD on Stentor-01) into the system's RAM (1GB on Stentor-01) for processing. Subsequent runs can be faster if the model file's data is still present in the operating system's disk cache (held in RAM).*

## 3. Managing Whisper.cpp and Models

### Updating Whisper.cpp

To update Whisper.cpp to the latest version and rebuild it:
1.  Navigate to the source directory:

```bash
cd ~/src/whisper.cpp
```

2.  Pull the latest changes from the repository:

```bash
git pull
```

3.  Re-run the compilation (make). If you used the `install-whisper-cpp.sh` script initially, it likely just ran `make`. You can do the same: (UNTESTED)

```bash
make clean && make
```

    Or, if you are unsure, you can re-run the installation script, as it's designed to handle existing installations by updating and recompiling: (TESTED)

```bash
~/stentor-01/scripts/server-setup/install-whisper-cpp.sh
```

### Discovering Available Models for Download

The Whisper.cpp project regularly adds new models or updates existing ones (including different quantization levels).
1.  **Using the Download Script:** The `download-ggml-model.sh` script within the `~/src/whisper.cpp/models/` directory can often list available models. Try running it without arguments or with a help flag if available:

```bash
cd ~/src/whisper.cpp/models
bash ./download-ggml-model.sh
```

    This might print a list of model names you can then use with the script (e.g., `bash ./download-ggml-model.sh medium.en-q5_0`).
2.  **Checking the Whisper.cpp GitHub Repository:** The most definitive source for available models is the official Whisper.cpp GitHub repository. Look for model files or documentation related to model availability.

### Listing Locally Installed Models

To see which models you have already downloaded to your server:
1.  **List Raw Model Files:** Navigate to the models directory and list its contents. Model files typically end with `.bin`.

```bash
ls -lh ~/src/whisper.cpp/models/
```

    From your example output, installed models include:
    `ggml-medium.en-q5_0.bin`
    `ggml-small.en-q5_1.bin`
    `ggml-tiny.en.bin`
    `ggml-base.en-q5_1.bin`

2.  **Get a Clean List of Usable Model Names:** For use with scripts like `process_audio.sh` (which constructs the full path and `ggml-` prefix), you can get a cleaner list of just the model names:

```bash
ls -1 ~/src/whisper.cpp/models/ggml-*.bin | sed -e 's|.*/ggml-||' -e 's|\.bin$||'
```

    This command would output names like:
```
base.en-q5_1
medium.en-q5_0
small.en-q5_1
tiny.en
```
    These are the names you would typically use in the `--models` argument for `queue_processor.sh`.
