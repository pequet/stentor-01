# Stentor Orchestration Architecture

## Overview

This document describes the orchestration layer that enables autonomous content harvesting and processing in the Stentor system. The architecture consists of two main automation components that work together to create a fully autonomous audio transcription pipeline.

## Architecture Components

### 1. Client-Side: Periodic Content Harvester

**Purpose:** Automatically discover and download new audio content from configured sources.

**Location:** `scripts/client-side/periodic_harvester.sh`

**Functionality:**
- Maintains a simple database/file of content sources (URLs)
- Runs periodically via cron job (e.g., every 2-4 hours)
- Checks each source for new content
- Downloads new content using existing `download_to_stentor.sh` script
- Logs activity and handles errors gracefully

**Supported Source Types:**
- YouTube video URLs
- YouTube playlist URLs  
- RSS feed URLs (podcasts, blogs)
- Any URL that yt-dlp can process

**Configuration File:** `scripts/client-side/content_sources.txt`
```
# Format: TYPE|URL|DESCRIPTION
youtube_playlist|https://www.youtube.com/playlist?list=PLxxx|Tech Talks
youtube_video|https://www.youtube.com/watch?v=xxx|Specific Video
rss|https://example.com/podcast.rss|Podcast Feed
```

### 2. Server-Side: Queue Processor

**Purpose:** Process downloaded audio files through the transcription pipeline.

**Location:** `scripts/audio-processing/queue_processor.sh`

**Functionality:**
- Monitors inbox directory for new MP3/audio files
- Implements robust locking to prevent concurrent execution
- Processes files in chronological order (oldest first)
- Uses existing `process_audio.sh` for transcription
- Handles success/failure cases with appropriate file management
- Prevents reprocessing of already-handled files
- Intelligently handles retryable errors from child scripts

**Lock File Management:**
- Lock file: `/tmp/stentor_queue_processor.lock`
- Includes trap for cleanup on script exit
- Failsafe: Removes lock if older than a configurable duration
- PID tracking for additional safety

**File Organization (Server-Side Main Workflow):**
```
$HOME/stentor_harvesting/  (Base directory for mounted client downloads & main processing stages)
├── inbox/              # New files to process (populated by client download script)
├── processing/         # Audio files currently being processed by queue_processor.sh
├── completed/          # Successfully processed audio files & their metadata
├── failed/            # Failed audio files & their metadata
└── logs/              # Detailed logs for each processing job by queue_processor.sh
```

**Temporary Processing Runs (Server-Side Individual Job Workspace):**
```
$HOME/stentor_processing_runs/ (Base for temporary files for each audio processing job)
└── [job_hash_timestamp]/    # Unique directory per process_audio.sh run
    ├── audio_workable.wav # Standardized WAV for processing
    ├── segments/          # Directory for WAV chunks if segmentation is used
    │   ├── segment_001.wav
    │   └── ...
    ├── audio_transcript.md # Detailed transcript
    ├── audio_transcript.txt # Clean transcript text
    └── processing_info.md # Metadata about the processing run
```

## Integration Points

### `process_audio.sh` as a Core Component

The `process_audio.sh` script is the engine of the server-side workflow, and includes the following features utilized by the orchestration layer:

1. **Clear Exit Codes:**
   - Exit 0: Success
   - Exit 1: General processing failure
   - Exit 10: Retryable lock file error

2. **Standardized Output:**
   - On success: All output is contained within a structured run directory.
   - On failure: Logs sufficient error details to its run directory for debugging.

3. **Internal Locking:**
   - Prevents concurrent execution of `process_audio.sh` itself.
   - Uses a separate lock file from the main queue processor.

### Client-Side Integration

The periodic harvester integrates with the existing infrastructure:

1. **Uses existing download_to_stentor.sh**
2. **Respects existing .env configuration**
3. **Leverages existing mount/unmount scripts**

## Workflow Diagrams

### Client-Side Workflow
```
[Cron Trigger] → [Read Sources] → [Check for New Content] → [Download via download_to_stentor.sh] → [Log Results]
```

### Server-Side Workflow
```
[Cron Trigger] → [Acquire Lock] → [Scan Inbox] → [Process Oldest File First] → [Move to Success/Failure] → [Release Lock]
```

## Configuration

### Client-Side Cron Job
```bash
# Run every 4 hours
0 */4 * * * /path/to/scripts/client-side/periodic_harvester.sh >> /var/log/stentor_harvester.log 2>&1
```

### Server-Side Cron Job
```bash
# Run every 1 minute
*/1 * * * * /path/to/scripts/audio-processing/queue_processor.sh >> /var/log/stentor_queue.log 2>&1
```

## Error Handling & Recovery

### Client-Side
- Network failures: Retry with exponential backoff
- Mount failures: Retry with exponential backoff
- Download failures: Log specific URL and continue

### Server-Side
- Processing failures: Move file to failed directory with error log
- Lock file issues: Implement failsafe removal and logging
- Disk space: Monitor and alert when approaching limits

## Monitoring & Logging

### Log Files
- Client: scripts/client-side/stentor_harvester.log
- Server: scripts/audio-processing/stentor_queue.log
- Processing: Individual logs in stentor_processing/logs/

### Key Metrics to Track (future development)
- Files downloaded per day
- Processing success/failure rates
- Average processing time per file
- Disk space utilization
- Queue depth and processing lag

## Anti-Reprocessing Strategy

### Client-Side
- Rely on yt-dlp for the existing download_archive.txt file to prevent re-downloading

### Server-Side
- Maintain processing history in `stentor_processing/processed_files.txt`
- Include file hash and processing timestamp
- Prevent reprocessing of moved files

## Resource Management

### Disk Space Management
- Automatic cleanup of old temporary files
- Configurable retention periods for completed/failed files
- Monitoring and alerting for disk space thresholds

### Processing Resources
- Single-threaded processing to manage CPU/memory
- Configurable timeout limits for stuck processes
- Graceful handling of resource exhaustion

## Security Considerations

### Client-Side
- Secure storage of SSH credentials in .env files
- Validation of URLs before processing
- Rate limiting to avoid overwhelming sources

### Server-Side
- Restricted file permissions on processing directories
- Input validation for all processed files
- Secure cleanup of temporary files

## Implementation Priority

1. [x] **Phase 1:** Document architecture (this document) 
2. [x] **Phase 2:** Enhance `process_audio.sh` with exit codes and locking 
3. [x] **Phase 3:** Implement server-side queue processor (`queue_processor.sh`) 
4. [x] **Phase 4:** Implement client-side periodic harvester (`periodic_harvester.sh`) 
5. [] **Phase 5:** End-to-end testing and monitoring (Status: Testing complete, analysis in progress)

## Future Enhancements

- Web interface for managing content sources
- Real-time monitoring dashboard
- Integration with notification systems
- Advanced content filtering and categorization
- Distributed processing across multiple droplets 