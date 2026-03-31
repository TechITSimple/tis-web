#!/bin/bash
# MANAGED BY TIS CORE - DO NOT EDIT

set -e

FORCE_UPDATE=0
if [[ "$*" == *"--force"* || "$*" == *"-f"* ]]; then
    FORCE_UPDATE=1
fi

SITE_NAME=$(basename "$PWD")
# Extract macro-environment name from the parent directory
ENV_NAME=$(basename "$(dirname "$PWD")")

# 1. EXPORT ISOLATION VARIABLES
# These tell Docker Compose which network to use and how to prefix containers
export COMPOSE_PROJECT_NAME="${ENV_NAME}-${SITE_NAME}"
export NETWORK_NAME="${ENV_NAME}-net"

# 2. COLD START CHECK
# If no containers exist for this specific project, force the build
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
    echo "[$SITE_NAME] 🚀 Cold start detected. Forcing initial build..."
    FORCE_UPDATE=1
fi

echo "[$SITE_NAME] 🔄 Checking for updates..."

# 3. PRE-UPDATE HOOK
if [ -f "pre-update.sh" ]; then
    echo "[$SITE_NAME] 🔗 Preparing and executing pre-update hook..."
    sudo chmod +x pre-update.sh
    source pre-update.sh
fi

# 3.5. GIT CONFIGURATION (Anti-Permission Errors)
# Configure Git to ignore chmod edits
sudo -u tis git config core.filemode false

# 4. GIT PULL & CONFLICT MANAGEMENT
LOCAL_COMMIT=$(git rev-parse HEAD)

echo "[$SITE_NAME] 📡 Fetching remote changes..."
sudo -u tis git fetch origin > /dev/null

# Check for potential conflicts
if ! sudo -u tis git merge-base --is-ancestor HEAD origin/main; then
    echo "[$SITE_NAME] ⚠️ CONFLICT DETECTED: Local changes would be overwritten."
    
    # Interactive prompt
    read -p "[$SITE_NAME] Do you want to FORCE the GitHub version (discards local changes)? [y/N]: " CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "[$SITE_NAME] 💥 Forcing remote version (git reset --hard)..."
        sudo -u tis git reset --hard origin/main > /dev/null
    else
        echo "[$SITE_NAME] ❌ Update aborted by user to protect local changes."
        exit 1
    fi
else
    # If no conflicts, normally pull
    sudo -u tis git pull > /dev/null
fi

REMOTE_COMMIT=$(git rev-parse HEAD)

# 5. DOCKER DEPLOYMENT
echo "[$SITE_NAME] 🏗️ Processing containers (Network: $NETWORK_NAME)..."
docker compose up -d --build --force-recreate> /dev/null

# 6. POST-UPDATE HOOK
if [ -f "post-update.sh" ]; then
    echo "[$SITE_NAME] 🔗 Preparing and executing post-update hook..."
    sudo chmod +x post-update.sh
    source post-update.sh
fi

echo "[$SITE_NAME] ✅ Update complete."
echo ""
