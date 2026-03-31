# TIS Web Manager (tis-web)

Global Command Line Interface (CLI) for managing the TechITSimple web infrastructure. It provides context-aware commands to bootstrap environments, install sites, and manage Docker container lifecycles seamlessly.

## 🚀 Installation

Follow these steps to install the CLI and configure global access and autocompletion on your VPS.

### 1. Clone the Repository
Navigate to your scripts directory and clone the repository using SSH:

```bash
mkdir -p /home/tis/scripts
cd /home/tis/scripts
git clone git@github.com:TechITSimple/tis-web.git
cd tis-web
```

### 2. Ensure Execution Permissions
Ensure the core bash scripts are executable (even if tracked by Git, this prevents umask issues):

```bash
chmod +x tis-web.sh
chmod +x tis-web-update.sh
```

### 3. Create Global Symlink
Create a symbolic link in `/usr/local/bin` to make the `tis-web` command available system-wide:

```bash
sudo ln -s /home/tis/scripts/tis-web/tis-web.sh /usr/local/bin/tis-web
```

### 4. Setup Autocompletion
Link the bash completion script to enable smart, context-aware `TAB` suggestions, then reload your session:

```bash
# Create the symlink for bash completion
sudo ln -s /home/tis/scripts/tis-web/bash_completion /etc/bash_completion.d/tis-web

# Apply changes to the current terminal session
source /etc/bash_completion.d/tis-web
```

---

## 🔄 Updating the CLI

When new features or bug fixes are pushed to the repository, you can update the CLI locally with a simple pull.

```bash
# Navigate to the tool directory
cd /home/tis/scripts/tis-web

# Pull the latest changes
git pull

# Reload completion rules in case the autocompletion logic was updated
source /etc/bash_completion.d/tis-web
```

---

## 🛠️ Usage

The CLI is context-aware. Depending on your current working directory (`/home/tis/websites`, an environment folder, or a specific site folder), arguments like `[env]` and `[site]` are automatically detected.

Run the built-in help command from anywhere to see all available actions and context rules:

```bash
tis-web help
```
