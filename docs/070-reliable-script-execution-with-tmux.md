# 070: Solving Premature Script Termination from SSH Disconnects

## 1. Problem

Long-running processes or scripts (like `queue_processor.sh`) that are started directly in an SSH session are terminated if the SSH connection drops. The lost connection kills the running script.

This is standard behavior, as the script is a child process of the shell session, and when the session ends, all its child processes are terminated.

## 2. Solution: Persistent Sessions with `tmux`

The solution is to use a **terminal multiplexer** like `tmux`. `tmux` creates a persistent session on the server that is independent of your SSH connection. You can start a script inside a `tmux` session, detach from that session (leaving it running in the background), and log out. When you log back in later, you can re-attach to the same session and see your script's output, even if your connection was dropped in the meantime.

## 3. Step-by-Step Guide to Using `tmux`

Here is a complete workflow for using `tmux` to run your audio processing scripts reliably.

### Step 1: Install `tmux` on the Server

First, connect to your server. Then, run the following command to install `tmux`.

```bash
sudo apt update && sudo apt install -y tmux
```

### Step 2: Start a New `tmux` Session

To start a new session, it's best to give it a descriptive name so you can easily identify it later.

```bash
tmux new -s audio-processing
```

Your terminal will clear, and you'll see a green status bar at the bottom. You are now inside the `audio-processing` `tmux` session.

### Step 3: Run Your Long-Running Script

Inside the `tmux` session, start your script as you normally would.

```bash
stentor-01/scripts/audio-processing/queue_processor.sh --cleanup-wav-files --cleanup-original-audio --models "small.en-q5_1,base.en-q5_1" --timeout-multiplier 20
```

The script will now run inside the `tmux` session, protected from disconnects.

### Step 4: Detach from the Session

To leave the session running in the background, you "detach" from it.

Press **`Ctrl+b`** and then press the **`d`** key.

You will return to your normal shell, and you'll see a message like `[detached (from session audio-processing)]`. The session and your script are still running on the server. You can now safely log out.

### Step 5: List and Re-attach to Sessions

When you log back into your server later, you can see all the running `tmux` sessions.

```bash
tmux ls
```

This will show a list, for example: `audio-processing: 1 windows (created Fri Jun  6 15:10:00 2025) (detached)`.

To re-attach to your session and check on your script:

```bash
tmux attach-session -t audio-processing
```

You will be dropped right back into the session, exactly where you left off.

### Step 6: Kill a Session

Once your script is finished and you no longer need the session, you can kill it. You can do this from inside the session by typing `exit` or from outside by running:

```bash
tmux kill-session -t audio-processing
``` 