# Stentor Audio Processing Automation

A streamlined automation system for processing audio content with Stentor.

## System Overview

The automation consists of three main components:

1. **`periodic_harvester.sh`** - Client-side script that reads URLs and downloads content
2. **`queue_processor.sh`** - Server-side daemon that processes queued audio files  
3. **`process_audio.sh`** - Server-side core processing script 

## Directory Structure

Remote:
```
stentor_harvesting/
├── inbox/           # Incoming audio files (queue)
├── processing/      # Currently being processed
├── completed/       # Successfully processed files
├── failed/          # Failed processing attempts
└── logs/            # Processing logs
```

Local:
```
$HOME/.stentor/
├── .env                     # Environment variables
├── logs/                    # Harvester and processor logs
├── content_sources.txt      # Simple URL list
├── periodic_harvester.lock  # Harvester lock file
├── queue_processor.lock     # Queue processor lock file
└── process_audio.lock       # Audio processor lock file
```

## Components

### periodic_harvester.sh (Client-side)

Reads URLs from a simple text file and calls the existing `download_to_stentor.sh` script.

**Features:**
- Simple URL list format (one per line, optional comments after `|`)
- Uses existing download infrastructure
- Proper locking with local `$HOME/.stentor/` location
- Dry-run support for testing

**Usage:**
```bash
# Normal operation
./periodic_harvester.sh

# Test what would be downloaded
./periodic_harvester.sh --dry-run

# Show help
./periodic_harvester.sh --help
```

**Content Sources Format (`$HOME/.stentor/content_sources.txt`):**
```
https://youtube.com/watch?v=xxx
https://youtube.com/playlist?list=xxx|My Favorite Playlist  
https://example.com/podcast.rss|Tech Podcast
# This is a comment line
```

### queue_processor.sh (Server-side)

Monitors the inbox directory and processes audio files using the enhanced `process_audio.sh`.

**Features:**
- Processes oldest files first
- Proper locking with remote `$HOME/.stentor/` location
- Anti-reprocessing logic
- Organized file management (completed/failed directories)
- Comprehensive logging
- Designed for cron execution

**Usage:**
```bash
# Manual run
./queue_processor.sh

# Dry run (show what would be processed)
./queue_processor.sh --dry-run
```

### process_audio.sh (Enhanced)

The core audio processing script with automation enhancements.

**Enhancements:**
- Standardized exit codes (0=success, 1=processing failure, 2=validation/dependency failure)
- Proper locking with remote `$HOME/.stentor/` location
- Structured output for automation
- Internal locking mechanism
- Comprehensive error handling

## Setup Instructions

### 1. Configure Environment

Create `$HOME/.stentor/.env`:
```bash
# Remote directory to mount (contains inbox, processing, completed, etc.)
STENTOR_REMOTE_AUDIO_INBOX_DIR="~/stentor_harvesting"

# Local mount point
LOCAL_MOUNT_POINT="$HOME/.stentor_droplet_mount"

# SSH connection details
STENTOR_DROPLET_USER="stentoruser"
STENTOR_DROPLET_HOST="your-droplet-ip"
```

### 2. Create Content Sources

Create a simple URL list in "$HOME/.stentor/content_sources.txt"

```text
https://youtube.com/watch?v=example1
https://youtube.com/playlist?list=example2|My Playlist
```

### 3. Set Up Server Processing

Add to crontab for automatic processing:

- local crontab:

- remote crontab:

...

## Usage Examples

### Manual Content Download
```bash
# Download a single URL
./scripts/client-side/download_to_stentor.sh "https://youtube.com/watch?v=xxx"

# Harvest from content sources
./scripts/audio-processing/periodic_harvester.sh
```

### Server Processing
```bash
# Process queue once
./scripts/audio-processing/queue_processor.sh

# Check what's in the queue
ls -la stentor_harvesting/inbox/

# Check processing status
tail -f $HOME/.stentor/logs/queue_processor.log
```

## Monitoring and Troubleshooting

### Check Processing Status
```bash
# View recent queue processor activity
tail -20 $HOME/.stentor/logs/queue_processor.log

# View recent harvester activity  
tail -20 $HOME/.stentor/logs/periodic_harvester.log

# Check for stuck processes
ps aux | grep -E "(queue_processor|periodic_harvester|process_audio)"
```

### Common Issues

**Lock file issues:**
```bash
# Remove stale locks if processes aren't running
rm -f $HOME/.stentor/*.lock
```

**Mount point issues:**
```bash
# Check if remote is mounted
mount | grep stentor_harvesting

# Manually unmount if needed
./scripts/client-side/unmount_droplet_yt.sh
```

**Permission issues:**
```bash
# Ensure scripts are executable
chmod +x scripts/audio-processing/*.sh
chmod +x scripts/client-side/*.sh
```

## Performance Tuning

### Adjust Processing Frequency
```bash
# More frequent processing (every 5 minutes)
*/5 * * * * /path/to/queue_processor.sh

# Less frequent processing (every hour)
0 * * * * /path/to/queue_processor.sh
```

### Optimize Whisper Models
Edit `process_audio.sh` to adjust model preferences:
- Use `tiny` or `base` for faster processing
- Use `small` or `medium` for better accuracy
- Use `large` for best quality (slower)

## Security Considerations

- Lock files in `$HOME/.stentor/` are user-accessible only
- SSH keys should be properly secured for remote mounting
- Content sources file should be readable only by the user
- Log files may contain URLs - secure appropriately

## Integration with Existing Scripts

This automation system works with your existing infrastructure:

- **`download_to_stentor.sh`** - Used by periodic_harvester.sh for actual downloads
- **`mount_droplet_yt.sh`** - Called automatically when needed
- **`unmount_droplet_yt.sh`** - Called automatically for cleanup
- **Existing `.env` configuration** - Fully compatible

## Maintenance

### Regular Tasks
```bash
# Clean old completed files (older than 30 days)
find stentor_harvesting/completed -name "*.wav" -mtime +30 -delete

# Clean old failed files (older than 7 days)  
find stentor_harvesting/failed -name "*.wav" -mtime +7 -delete

# Rotate logs (keep last 100 lines)
tail -100 $HOME/.stentor/logs/queue_processor.log > /tmp/log.tmp && mv /tmp/log.tmp $HOME/.stentor/logs/queue_processor.log
```

### Monitor Disk Usage
```bash
# Check processing directory size
du -sh stentor_harvesting/

# Check for large files
find stentor_harvesting/ -size +100M -ls
```

## License

This automation system is part of the Stentor project and follows the same licensing terms.

## Support

For troubleshooting:

1. Check the log files in `$HOME/.stentor/logs/`
2. Verify all dependencies are installed (ffmpeg, yt-dlp, whisper)
3. Ensure proper file permissions on all scripts
4. Check that `.env` configuration is correct 