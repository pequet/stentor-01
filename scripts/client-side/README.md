# Stentor Client-Side Automation

This document outlines the client-side scripts responsible for discovering and downloading new audio content for the Stentor system. These scripts are intended to be run periodically on a client machine to feed new content to the server-side processing queue.

For details on the server-side components that process the audio, see the [main automation README](../audio-processing/README.md).

## Workflow Overview

The client-side process is a two-step pipeline:

1.  **Discovery (`harvest_webpage_links.sh`)**: Scans configured webpages for new YouTube links.
2.  **Downloading (`periodic_harvester.sh`)**: Reads a master list of URLs and downloads the content to the remote server's inbox.

This decouples the discovery of new content from the download process, allowing for a robust and automated workflow.

## Entry-Point Scripts

These are the two scripts you will typically interact with and set up for periodic execution (e.g., via `cron`).

### 1. `harvest_webpage_links.sh` (The Discoverer)

This script automates the discovery of new YouTube links from one or more webpages.

**Purpose:**
- Scrapes target URLs (defined in `$HOME/.stentor/target_webpage_url.txt`).
- Extracts YouTube video links.
- Compares found links against the master content list (`$HOME/.stentor/content_sources.txt`).
- Prepends any new, unique links to the master list, making them available for the harvester.

**Usage:**
- Designed to be run automatically.
- It manages its own browser instance via MCP to scrape dynamic pages.

```bash
# Run the harvester manually
./scripts/client-side/harvest_webpage_links.sh
```

**Setup (`cron`):**
Run this script periodically to keep your content source list up-to-date. Running it once or twice a day is usually sufficient.

```cron
# Run the webpage link harvester every day at 2 AM
0 2 * * * /path/to/stentor/scripts/client-side/harvest_webpage_links.sh >> /path/to/stentor/logs/webpage_harvest.log 2>&1
```

---

### 2. `periodic_harvester.sh` (The Downloader)

This script reads the master list of content sources and downloads the media.

**Purpose:**
- Reads all URLs from `$HOME/.stentor/content_sources.txt`.
- For each URL, it calls the `download_to_stentor.sh` script to handle the actual download.
- This script manages mounting the remote directory and ensures that downloads are sent to the server's `inbox/`.

**Usage:**
- Can be run manually to process the entire list of sources.
- The `--use-break-on-existing` flag is highly recommended for frequent runs to stop processing a playlist once it finds an already-downloaded item.

```bash
# Run the harvester manually
./scripts/client-side/periodic_harvester.sh

# Run with the break-on-existing optimization (recommended for cron)
./scripts/client-side/periodic_harvester.sh --use-break-on-existing
```

**Setup (`cron`):**
Run this script more frequently to ensure new content is downloaded promptly.

```cron
# Run the periodic harvester every hour
0 * * * * /path/to/stentor/scripts/client-side/periodic_harvester.sh --use-break-on-existing >> /path/to/stentor/logs/periodic_harvest.log 2>&1
```

## Supporting Scripts

These scripts are not meant to be run directly as part of the periodic automation but are essential utilities called by the entry-point scripts.

-   **`download_to_stentor.sh`**: The core workhorse that handles the download, metadata fetching, and remote transfer for a *single* URL. It is called by `periodic_harvester.sh`.
-   **`mount_droplet_yt.sh`**: Handles mounting the remote server directory via `sshfs`.
-   **`unmount_droplet_yt.sh`**: Handles unmounting the remote server directory.

## Configuration

-   **`$HOME/.stentor/target_webpage_url.txt`**: A simple text file containing the URLs for `harvest_webpage_links.sh` to scrape, one URL per line.
-   **`$HOME/.stentor/content_sources.txt`**: The master list of YouTube video/playlist URLs to be downloaded. This file is managed by `harvest_webpage_links.sh` and read by `periodic_harvester.sh`.
-   **`$HOME/.stentor/stentor.conf`**: Contains environment variables for the remote server connection (mount point, user, host), used by the mount/unmount and download scripts. 