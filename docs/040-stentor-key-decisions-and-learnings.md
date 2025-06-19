# 040: Stentor Key Decisions & Learnings

*   **SSH Key Management Strategy:**
    *   One unique SSH key pair (Ed25519 recommended) is generated per client machine needing server access.
    *   The comment for each key typically uses a format like `username@client-machine-identifier` (e.g., `jsmith@mac-mini-m4`, `jsmith@dev-laptop`).
    *   The public key from each authorized client machine is added to the relevant user's `~/.ssh/authorized_keys` file on the server.
    *   This strategy compartmentalizes access by client device, enhancing security (if one client device is compromised, only its key needs to be revoked from servers) while maintaining reasonable manageability.
*   **OS Choice:** Ubuntu 24.04 LTS for stability, long-term support, strong software compatibility with our stack. See [Initial Setup](./000-stentor-droplet-provisioning-and-initial-setup.md) for details.
*   **Droplet Hardware:** Premium AMD CPU with NVMe SSD chosen for transcription performance (CPU-intensive) and fast file operations (MP3→WAV conversion, silence analysis, model loading). Worth the modest additional cost.
*   **Swap Space:** 2GB swap configured on 1GB RAM droplet as safety net against OOM errors, not as substitute for adequate RAM. Allows handling temporary memory spikes and emergency situations.
*   **`yt-dlp` Location:** Run locally, transfer audio to droplet to protect server IP.
*   **Transcription Engine:** `whisper.cpp` is chosen for its efficiency on low-cost droplets.
*   **Whisper Model Performance (1GB RAM Droplet):**
    *   `ggml-tiny.en.bin`: Successful for audio files approximately 45-60 minutes long (fast, lower quality). Successful for longer content as well (e.g., podcast-length episodes of over an hour when combined with appropriate segmentation via `process_audio.sh`).
    *   `ggml-base.en-q5_1.bin`: Successful for shorter audio files (e.g., up to ~20 minutes). For longer files (e.g., 45-60 minutes), this model is likely to cause Out Of Memory (OOM) errors or fail on a 1GB RAM droplet unless aggressive segmentation is used.
    *   Larger models (e.g., `small.en` variants) are generally unsuitable for 1GB RAM due to OOM errors, especially with longer audio segments.
    *   **Key Strategy for Long Audio:** To transcribe long audio files (e.g., 1 hour or more) with more capable models like `base.en-q5_1` on a 1GB RAM droplet, audio segmentation is crucial. By detecting silences and splitting the audio into smaller, manageable chunks, each chunk can be processed individually, circumventing OOM limitations.
*   **Vibe Tools Feasibility (1GB RAM Droplet):**
    *   Basic commands (`ask`, `web` with some providers) are generally feasible.
    *   Resource-intensive commands (e.g., `browser` automation with Playwright, or `repo` analysis on large codebases) will strain or exceed 1GB RAM and are not recommended for concurrent use with Whisper or if Playwright is installed. If heavy Vibe Tools usage is planned, a separate, more powerful droplet is advisable.
*   **`repomix.config.json` for `vibe-tools repo`:**
    *   **Learning (2025-05-22):** The `include` array in `repomix.config.json` is critical. `vibe-tools repo` will only process files matching these patterns. Shell scripts (`**/*.sh`) or other necessary file types must be explicitly added to this array if they are not covered by existing patterns, otherwise `repo` will lack full context.
*   **`vibe-tools ask` Model Identifiers:**
    *   **Learning (2025-05-22):** Using general, non-dated model identifiers (e.g., `claude-3-5-haiku-latest`) in documentation and examples is more robust than specific dated versions, which can become outdated quickly. Always advise users to check the AI provider's official documentation for current model names.
*   **Whisper.cpp Performance Update (1GB RAM Droplet):**
    *   **Learning (2025-05-22):** Initial tests show that even a quantized medium English model can successfully process very short audio samples (a few seconds) on the 1GB Stentor-01 droplet. This is more promising than initially anticipated for small segments, though performance with longer segments using this model still needs verification and likely relies on effective chunking.
*   **Workflow Automation Potential:**
    *   **Insight (2025-05-22):** The combination of `vibe-tools` (for AI-driven logic and interaction), FFmpeg (for audio manipulation: conversion, silence detection, chunking), and Whisper.cpp (for transcription) presents a powerful and highly automatable toolchain for the Stentor project's objectives.
*   **Future Architectural Considerations:** If the system grows to include more services (e.g., a web frontend/API, database, orchestrator), consider a multi-droplet architecture (e.g., Stentor for Whisper, a separate droplet for web services/CodeIgniter, and potentially another for Vibe Tools if usage becomes heavy).
*   **Resource Usage During Extended Transcription (process_audio.sh):**
    *   **Observation (2025-05-23):** During extended transcription tasks (e.g., processing podcast-length audio using `process_audio.sh` with the `tiny.en` model and segmentation), CPU and memory usage can be consistently high. This is an expected behavior for the dedicated Stentor-01 server and is considered acceptable as long as overall system stability is maintained and transcriptions complete successfully.
*   **Last Updated:** 2025-05-23_1436

This document outlines key architectural decisions, patterns, and significant learnings from the Stentor-01 project.

## Key Decisions

### 1. Robust Lock File Handling with Retryable Exit Codes

*   **Decision Date:** 2025-06-05
*   **Context:** The `queue_processor.sh` script would incorrectly mark audio files as "failed" if the child `process_audio.sh` script could not run because it was already locked. This treated a temporary, expected condition as a permanent failure.
*   **Decision:**
    1.  A specific, non-standard exit code (`10`) was introduced in `process_audio.sh`. This code is now used exclusively to signal that the script could not run due to a lock contention (either another instance is running or a recent one just finished).
    2.  The parent script, `queue_processor.sh`, was updated to recognize and handle exit code `10`. Instead of moving the file to the `failed/` directory, it moves it back to the `inbox/`.
*   **Rationale:** This change creates a more resilient, self-healing system. It correctly distinguishes between permanent processing failures (which require manual intervention) and transient, retryable conditions (which should be handled automatically). By moving locked files back to the inbox, the system ensures that no data is prematurely discarded and that all files get a fair chance to be processed.
*   **Impact:** The processing pipeline is significantly more robust. The risk of losing work due to simple, expected race conditions in a parallel processing environment is eliminated.

### 2. Default Help Text for Command-Line Scripts

*   **Decision Date:** 2025-06-05
*   **Context:** Core scripts like `queue_processor.sh` had command-line options that were not easily discoverable without reading the script's source code.
*   **Decision:**
    1.  Key scripts will now check if they were run without any parameters.
    2.  If no parameters are provided, or if a `-h`/`--help` flag is used, the script will display a help message detailing its usage and available options.
*   **Rationale:** This is a standard UX convention for command-line tools that dramatically improves usability and discoverability. It allows users to quickly understand how to interact with a script without needing to inspect its code.
*   **Impact:** Project scripts are easier to use, understand, and debug.

**Last Updated:** 2025-06-19 