#!/bin/bash

# Standard Error Handling
set -e
# set -u # Removed due to potential issues with nproc in some environments if not set
set -o pipefail

# ██ ██   Stentor: Audio Processing & Transcription System
# █ ███   Version: 1.0.0
# ██ ██   Author: Benjamin Pequet
# █ ███   GitHub: https://github.com/pequet/stentor-01/
#
# Purpose:
#   Automates the installation of Whisper.cpp and a default model (tiny.en).
#   Updates system packages, installs dependencies, clones/updates the repository,
#   compiles the software, and downloads the model.
#
# Features:
#   - Updates system and installs necessary build dependencies (ffmpeg, build-essential, git, etc.).
#   - Clones the Whisper.cpp repository or pulls the latest changes if it already exists.
#   - Compiles Whisper.cpp using all available processor cores.
#   - Downloads a default English model (tiny.en) automatically.
#   - Provides instructions for downloading other models.
#
# Usage:
#   ./install-whisper-cpp.sh
#   It is recommended to run this script in a directory where you want the 'src' folder for Whisper.cpp to be created (e.g., your home directory).
#
# Dependencies:
#   - Standard Unix utilities: sudo, apt, git, make, nproc, wget, bash, cd.
#   - Build tools: build-essential, cmake, pkg-config.
#   - ffmpeg: For audio processing capabilities often used with Whisper.
#
# Changelog:
#   1.0.0 - 2025-05-25 - Initial release for automated Whisper.cpp installation.
#
# Support the Project:
#   - Buy Me a Coffee: https://buymeacoffee.com/pequet
#   - GitHub Sponsors: https://github.com/sponsors/pequet

# * Source Utilities
source "$(dirname "$0")/../utils/messaging_utils.sh"

# * Initial Setup
display_status_message " " "Starting: Whisper.cpp Installation Script"

# ** Update System and Install Dependencies
display_status_message "i" "Info: Updating system packages and installing dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y ffmpeg build-essential git pkg-config cmake wget
echo "INFO: Dependencies installed successfully."

# ** Clone the Whisper.cpp Repository
display_status_message "i" "Info: Cloning Whisper.cpp repository..."
mkdir -p ~/src
cd ~/src

if [ -d "whisper.cpp" ]; then
  echo "INFO: whisper.cpp directory already exists. Pulling latest changes..."
  cd whisper.cpp
  git pull
else
  git clone https://github.com/ggerganov/whisper.cpp.git
  cd whisper.cpp
fi
echo "INFO: Whisper.cpp repository cloned/updated successfully."

# ** Compile Whisper.cpp
display_status_message "i" "Info: Compiling Whisper.cpp..."
make -j$(nproc) > ~/whisper_compilation_log.txt 2>&1 # Compile and log all output
echo "INFO: Whisper.cpp compilation attempt finished. Check ~/whisper_compilation_log.txt for details."

# Check if the known executable was created
if [ -f ./build/bin/main ]; then
    echo "INFO: Main executable successfully created at: ./build/bin/main"
else
    display_status_message "!" "Failed: Whisper.cpp main executable NOT created. Review ~/whisper_compilation_log.txt"
fi

# ** Download a Default Whisper Model
DEFAULT_MODEL="tiny.en"
display_status_message "i" "Info: Navigating to models directory to download default model ($DEFAULT_MODEL)..."
cd models

echo "INFO: Downloading default model: $DEFAULT_MODEL..."
bash ./download-ggml-model.sh "$DEFAULT_MODEL"
if [ -f "ggml-$DEFAULT_MODEL.bin" ]; then
  echo "INFO: Default model ($DEFAULT_MODEL) downloaded successfully."
else
  display_status_message "!" "Failed: Could not download default model ($DEFAULT_MODEL). Check output."
fi

# ** List Available Models
display_status_message "i" "Info: Listing all available GGML models for manual download:"
echo "--------------------------------------------------------------------"
bash ./download-ggml-model.sh || true # List models; continue if this command exits non-zero
echo "--------------------------------------------------------------------"
echo "You can download other models using:"
echo "cd ~/src/whisper.cpp/models && bash ./download-ggml-model.sh <model_name>"
echo "--------------------------------------------------------------------"

cd ~/src/whisper.cpp # Return to whisper.cpp root

if [ -f ./build/bin/main ]; then
  display_status_message "x" "Completed: Whisper.cpp installation and default model download."
  echo "The main executable is at: $(pwd)/build/bin/main"
else
  display_status_message "!" "Completed with ERRORS: Whisper.cpp installation failed (main executable not found)."
fi
echo "Models are in: $(pwd)/models"
echo "--------------------------------------------------------------------"
echo "To run transcriptions, first ensure you are in the whisper.cpp directory:"
echo "cd ~/src/whisper.cpp"
echo "Then you can use commands like:"
echo "./build/bin/main -m models/ggml-tiny.en.bin -f samples/jfk.wav"
echo "--------------------------------------------------------------------" 