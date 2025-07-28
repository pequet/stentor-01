# 010: Installing Node.js and Vibe Tools on Stentor

This document outlines the steps to install Node.js (which includes npm, the Node Package Manager) and the `vibe-tools` CLI on the Stentor-01 server. These tools are foundational for interacting with AI services and managing project dependencies.

**Prerequisites:**

*   The Stentor-01 server has been provisioned and hardened as per `docs/000-stentor-droplet-provisioning-and-initial-setup.md`.
*   You are logged into the Stentor-01 server as your limited sudo-enabled user (e.g., `$STENTOR_USER`).

---

## Installation Steps

1.  **Ensure `curl` is installed:**
    `curl` is a command-line tool required to download the NodeSource setup script in the next step.

```bash
# Update package lists and install curl if not already present
sudo apt update && sudo apt install curl -y
```

2.  **Add NodeSource Repository and Install Node.js (LTS):**
    NodeSource provides up-to-date Node.js packages. This step configures your system to use their repository and then installs the latest Long-Term Support (LTS) version of Node.js. LTS versions are recommended for stability.

```bash
# Download and execute the NodeSource setup script for the latest LTS Node.js
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
# Install Node.js (this also installs npm)
sudo apt-get install nodejs -y
```

3.  **Verify Node.js and Initial npm Installation:**
    Confirm that Node.js and npm have been installed correctly by checking their versions.

```bash
# Check Node.js version (e.g., should show v20.x.x or a similar LTS version)
node -v
# Check the initially bundled npm version
npm -v
```

4.  **Update npm to the Latest Version:**
    The version of npm bundled with Node.js might not be the absolute latest. It's good practice to update npm to its most recent version to get the latest features and bug fixes for the package manager itself.

```bash
# Install the latest version of npm globally
sudo npm install -g npm@latest
# Verify the updated npm version
npm -v
```

5.  **Install `vibe-tools` Globally:**
    `vibe-tools` is a command-line interface used throughout this project to interact with various AI models and services.

```bash
# Install vibe-tools globally using npm
sudo npm install -g vibe-tools
# Verify vibe-tools installation by checking its version
vibe-tools --version
```

6.  **Configure API Keys for `vibe-tools`:**
    `vibe-tools` requires API keys to authenticate with AI service providers (e.g., OpenAI, Google Gemini). These keys are stored securely in a `.env` file within the `~/.vibe-tools/` directory.

```bash
# Create the configuration directory if it doesn't already exist
mkdir -p ~/.vibe-tools
# Create or edit the .env file using a text editor like nano
nano ~/.vibe-tools/.env
```

    Inside `~/.vibe-tools/.env`, add your API keys, one per line. **These are sensitive credentials; handle them securely and do not commit them to version control.**

    Example format:
    
```env
OPENAI_API_KEY="your_openai_api_key_here"
GEMINI_API_KEY="your_gemini_api_key_here"
PERPLEXITY_API_KEY="your_perplexity_api_key_here"
ANTHROPIC_API_KEY="your_anthropic_api_key_here"
OPENROUTER_API_KEY="your_openrouter_api_key_here"
# Add other keys for other providers as needed
```

    Save the file and exit the editor (in `nano`: `Ctrl+O` to write out, `Enter` to confirm, `Ctrl+X` to exit). `vibe-tools` will automatically load these keys when it runs.

7.  **`vibe-tools` Functionality Examples:**
    Test `vibe-tools` connectivity and explore its different functionalities with these examples. Ensure your API keys are configured in `~/.vibe-tools/.env`.

    **Basic Web Query:**
    *(Requires an API key for a web-enabled provider like Perplexity or Gemini)*
```bash
vibe-tools web "What is the capital of France?"
```

    **Repository-Aware Query (Codebase Analysis):**
    *(Run from your project root, e.g., `~/stentor-01`. Ensure `repomix.config.json` includes relevant file types like `**/*.sh`)*
```bash
vibe-tools repo "Explain the overall purpose and interaction of the scripts in the 'scripts/server-setup/' directory of the Stentor project."
```

    **Direct AI Prompt (`ask` command):**
    *(Model names can change; always refer to the AI provider's official documentation for the latest model identifiers.)*
```bash
# Example using Anthropic (ensure your API key is correctly configured)
vibe-tools ask "Generate a short, upbeat welcome message for a user starting a new audio transcription session with a tool called Stentor." --provider anthropic --model claude-3-5-haiku-latest
```

    **Note on Saving Output:** For commands that produce extensive output (especially from `repo` or complex `ask` prompts), consider using the `--save-to` flag to capture the results in a file. This aligns with rule `285-vibetools-output-to-inbox.mdc`. Example:
    `vibe-tools repo "Detailed analysis of module X" --save-to=inbox/YYYY-MM-DD_HHMM-repo-analysis-module-X.md`
    *(Replace `YYYY-MM-DD_HHMM` with the actual timestamp as per rule `280-inbox-file-naming.mdc`.)*

---

This completes the installation and initial configuration of Node.js and `vibe-tools` on your Stentor-01 server. 