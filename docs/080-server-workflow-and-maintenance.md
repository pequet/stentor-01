---
type: guide
domain: methods
subject: Stentor
status: draft
summary: "A comprehensive guide to the server-side workflow for Stentor, including manual operation with tmux, automation with cron, and maintenance procedures."
---

# 080: Stentor Server Workflow, Automation, and Maintenance

This guide provides a complete workflow for operating and maintaining the Stentor audio processing system on the server. It covers both manual, interactive sessions and fully automated processing using cron.

## 1. Connecting to the Server

First, connect to your Droplet using SSH with your designated user.

```bash
ssh your_user@your_droplet_ip
```

## 2. Running the Queue Processor Manually (with `tmux`)

For long-running tasks, such as processing a large backlog of files, you **must** use `tmux`. This ensures the script continues to run even if your SSH connection is lost.

> **Note:** This is a summary of the full guide available at [070-reliable-script-execution-with-tmux.md](070-reliable-script-execution-with-tmux.md).

### Step-by-Step `tmux` Workflow

1.  **Start a Named Session:**
    Give your session a memorable name.

    ```bash
    tmux new -s audio-processing
    ```

2.  **Run the Queue Processor:**
    Inside the `tmux` session, run the `queue_processor.sh` script with the desired flags.

    **Recommended Production Command:**

    ```bash
    ~/stentor-01/scripts/audio-processing/queue_processor.sh --cleanup-wav-files --cleanup-original-audio --models "medium.en-q5_0,small.en-q5_1,base.en-q5_1" --timeout-multiplier 20
    ```

3.  **Detach from the Session:**
    To leave the script running in the background, press **`Ctrl+b`** then **`d`**. You can now safely log out.

4.  **Re-attach to the Session:**
    When you log back into the server, you can list sessions (`tmux ls`) and re-attach to check on progress:

    ```bash
    tmux attach-session -t audio-processing
    ```

## 3. Automating the Queue with Cron

For continuous, automatic processing of new files in the inbox, you must set up a cron job. The script has a built-in locking mechanism to prevent multiple instances from running simultaneously, making it safe for frequent execution.

### Step 1: Edit the Crontab

Open the crontab editor for your user:

```bash
crontab -e
```

### Step 2: Add the Cron Job

Add the following line to the file. This command will run the queue processor every **5 minutes**.

```cron
*/5 * * * * /home/khbeqrsuofepgvew/stentor-01/scripts/audio-processing/queue_processor.sh --cleanup-wav-files --cleanup-original-audio --models "medium.en-q5_0,small.en-q5_1,base.en-q5_1" --timeout-multiplier 20 > /home/khbeqrsuofepgvew/.stentor/logs/cron.log 2>&1
```

**Explanation of the command:**
*   `*/5 * * * *`: Runs the command every 5 minutes.
*   `.../queue_processor.sh ...`: The full path to the script with the recommended production flags.
*   `> .../cron.log 2>&1`: Redirects all output (both standard and error) to a dedicated cron log file for easy debugging.

Save and exit the editor. The cron job is now active.

## 4. Understanding `queue_processor.sh` Arguments

If you run the script with no arguments (`./queue_processor.sh`), it will display a help message and exit. Here are the key flags for production use:

*   `--cleanup-wav-files`: **(Recommended)** On success, deletes temporary WAV files created during transcription. This saves significant disk space.
*   `--cleanup-original-audio`: **(Recommended)** On success, deletes the original source audio file from the `completed` directory. Use this once you are confident the transcription process is reliable.
*   `--models "model1,model2,..."`: Specifies a comma-separated list of Whisper models to try in sequence. The script will use the first one that works. The recommended list `medium.en-q5_0,small.en-q5_1,base.en-q5_1` provides a good balance of quality and resilience.
*   `--timeout-multiplier N`: A multiplier to adjust the timeout for audio segment processing. The default should be sufficient, but a value like `20` provides a larger safety margin for very slow models or system load.
*   `--aggressive-cleanup`: A meta-flag that enables all cleanup options, including `--cleanup-run-logs`, which removes the detailed logs for each specific run. It's generally better to use the more granular flags above unless you need to aggressively conserve disk space.

### Safe Default for Large Backlogs

If you run the `queue_processor.sh` script with a simple, non-interfering flag (like `queue_processor.sh --process-now`, where `--process-now` is not a real flag), it will exhibit a "safe default" behavior:

*   **No Cleanup:** It will not delete any original audio or temporary WAV files.
*   **Fast Model:** It will use the default `tiny.en` Whisper model, which is very fast but less accurate than larger models.

This behavior is ideal for processing a large backlog of files quickly without losing any data. You get a usable, searchable transcript for every file, which you can then upgrade later.

## 6. Strategy for Re-Processing Files

If you have performed a quick first pass with the `tiny.en` model and want to re-transcribe specific files with a higher-quality model, follow these steps:

1.  **Identify the File:** Note the original filename of the audio you want to re-process (e.g., `My-Podcast-Episode.mp3`).
2.  **Remove from History:** The script keeps a record of processed files to avoid re-doing work. You need to remove the entry for your target file from the history log. The log is located at `~/stentor_harvesting/processed_files.txt`.
3.  **Move File Back to Inbox:** Move the original audio file from `~/stentor_harvesting/completed/` back to `~/stentor_harvesting/inbox/`.
4.  **Run with High-Quality Model:** The next time the cron job runs (or if you trigger it manually with the recommended production command), it will pick up the file and process it with the better models.

## 7. System Health Checks & Maintenance

Periodically, you should perform these checks to ensure the system is running smoothly.

### 1. Check for Failed Files

The most important check is the `failed` directory.

```bash
ls -l ~/stentor_harvesting/failed/
```

If this directory contains files, it means the `process_audio.sh` script failed to transcribe them after multiple attempts. You should examine the corresponding log files in `~/stentor_harvesting/logs/` to diagnose the issue.

### 2. Check for Stuck Files

The `processing` directory should normally be empty. If files are "stuck" here for an extended period (more than a few hours), it could indicate a problem with a running script or a stale lock file.

```bash
ls -l ~/stentor_harvesting/processing/
```

**What to do:**
1.  Check if a `queue_processor.sh` or `process_audio.sh` process is running (`ps aux | grep process_audio`).
2.  If no process is running, you may need to manually clear the lock file at `~/.stentor/process_audio.lock` and move the stuck files back to the `~/stentor_harvesting/inbox/` to be re-queued.

### 3. Review the Main Log Files

*   **Queue Processor Log:** General operations of the main queue script.
    ```bash
    tail -f ~/.stentor/logs/queue_processor.log
    ```
*   **Cron Job Log:** Output from the automated cron runs.
    ```bash
    tail -f ~/.stentor/logs/cron.log
    ```

These logs will give you a high-level overview of the system's activity and any errors encountered. 