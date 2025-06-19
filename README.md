# Project Stentor: Whisper & Automation Droplet

This project was built for tinkerers, developers, and knowledge managers who want to build a personal, machine-assisted system for learning. It is a self-hosted, automated pipeline that turns ephemeral spoken content into a permanent, private, and searchable knowledge base. At its core, it uses the powerful **`whisper.cpp`** engine for highly accurate local transcriptions, and the **`vibe-tools`** suite for AI-assisted analysis, summarization, and querying of your new library.

If you've ever wished you could "grep" a podcast, or wanted to build a private library of insights from your favorite sources, this project is for you.

The project's design is guided by two core ideas: the principle of **Augmenting Returns** and the **Productivity Pyramid** metaphor. Every new piece of knowledge added doesn't just add value but multiplies the value of the entire network. The pyramid provides a model for this compounding growth, visualizing the path from raw data (transcripts) to interconnected wisdom (analysis). As information moves up the pyramid, its value compounds.

## About the Name

**Stentor** was a herald in Greek mythology, known not just for his loud voice, but for his role as a clear and powerful communicator. The name was chosen to evoke the idea of amplifying and broadcasting knowledge from spoken content.

## How It Works: The Flow of Knowledge

Stentor's workflow is designed for robust, set-and-forget automation. This system is composed of two primary components: a **client-side harvester** that runs on your local machine (or a remote server) and a **server-side processor** that runs on the remote Stentor droplet.

1.  **Harvest (Client):** A script on your local machine (`periodic_harvester.sh`) scans a list of your favorite YouTube channels, playlists, or podcast feeds for new content.
2.  **Download (Client):** New episodes are downloaded as audio and securely transferred to your remote Stentor server.
3.  **Process (Server):** The server-side scripts process each file in a queue, segmenting the audio for efficiency.
4.  **Transcribe (Server):** The powerful `whisper.cpp` engine performs highly accurate transcription on the server.
5.  **Analyze (Client/Server):** With a complete transcript available, you can use **Vibe Tools** to perform any AI task you can imagine.

## Key Features

-   **Fully Automated:** Set it up once and continuously capture content from your favorite sources.
-   **Highly Efficient:** Optimized to run `whisper.cpp` on low-cost, resource-constrained servers (e.g., even a small $7/month, 1GB RAM DigitalOcean Droplet is capable of running quantized, English-specific models like `medium.en-q5_0` at the time of writing).
-   **Robust and Resilient:** Features include intelligent file locking, retry logic, and clear logging to ensure no content is missed.
-   **Extensible with AI:** Tightly integrated with **Vibe Tools** for powerful, customizable post-processing.
-   **Self-Hosted & Private:** You own your data. Transcripts and processed content reside on your own server.
-   **Well-Documented:** Comes with detailed guides for provisioning, installation, and understanding the workflow.

## Installation and Setup

The detailed setup, software installation, and workflow for the Stentor droplet are documented in the `docs/` directory. Please refer to these documents in order:

1.  **[000: Droplet Provisioning & Initial Setup](docs/000-stentor-droplet-provisioning-and-initial-setup.md)**: Covers initial droplet provisioning, user setup, and basic server hardening.
2.  **[010: Installing Node.js and Vibe Tools](docs/010-installing-nodejs-and-vibe-tools.md)**: Details the installation of Node.js, npm, and `vibe-tools` on the server.
3.  **[020: Installing FFmpeg and Whisper.cpp](docs/020-installing-ffmpeg-and-whisper-cpp.md)**: Covers the installation of FFmpeg and `whisper.cpp` on the server.
4.  **[030: Audio Processing Workflow](docs/030-stentor-audio-processing-workflow.md)**: Describes the end-to-end audio processing workflow, including file transfer and scripting.

## Quick Commands / Cheat Sheet

The following commands are for operating the Stentor system after it has been fully installed and configured as per the documentation.

<details>
<summary>Client-Side Operations</summary>
<br />

Run these from your local machine to manage the remote filesystem and fetch new content.

> **Run Content Harvester**
> ```bash
> # Scan sources, download new content, and transfer to the droplet
> ./scripts/client-side/periodic_harvester.sh
> ```
>
> -   **Configuration**: This script reads a list of YouTube or podcast URLs from `~/.stentor/content_sources.txt`, one URL per line.

> **Mount/Unmount Droplet**
> ```bash
> # Mount the remote filesystem to your local machine
> ./scripts/client-side/mount_droplet_yt.sh
>
> # Unmount the remote filesystem
> ./scripts/client-side/unmount_droplet_yt.sh
> ```

> **Harvesting Webpage Links (Optional & Experimental)**
> ```bash
> ./scripts/client-side/harvest_webpage_links.sh
> ```
> -   **Purpose**: This script uses [Browser MCP](https://docs.browsermcp.io/welcome) to automate a browser and find new YouTube links on the pages you specify.
> -   **Configuration**: You must list the full URLs of the pages you want to scrape in `~/.stentor/target_webpage_url.txt`, one URL per line. New discoveries are added to `~/.stentor/content_sources.txt`.
> -   **Note**: This script is fragile due to its reliance on external tools and website structures.

</details>

<details>
<summary>Server-Side Operations</summary>
<br />

`ssh` into your droplet and run these commands to process audio files.

> **Process the Entire Queue**
> ```bash
> # Process all pending audio files in the harvest queue
> ./scripts/server-side/queue_processor.sh
> ```

> **Process a Single File Manually**
> ```bash
> # Process a single audio file on demand
> ./scripts/server-side/process_audio_file.sh /path/to/audiofile.mp3
> ```

</details>

## License

This project is licensed under the MIT License. 

## Support the Project

If you find this project useful and would like to show your appreciation, you can:

-   [Buy Me a Coffee](https://buymeacoffee.com/pequet)
-   [Sponsor on GitHub](https://github.com/sponsors/pequet)
-   [Deploy on DigitalOcean](https://www.digitalocean.com/?refcode=51594d5c5604) ($ affiliate link $) 

Your support helps in maintaining and improving this project. Thank you!
