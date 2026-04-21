#!/bin/bash
# FILE: tis-web-update.sh
# Handles Git conflict resolution and Docker rebuilds.
# Note: Hooks (pre-up/post-up) and permissions are handled by the main CLI.

set -e

FORCE_UPDATE=0
if [[ "$*" == *"--force"* || "$*" == *"-f"* ]]; then
    FORCE_UPDATE=1
fi

SITE_NAME=$(basename "$PWD")
# Extract macro-environment name from the parent directory
ENV_NAME=$(basename "$(dirname "$PWD")")

# 1. EXPORT ISOLATION VARIABLES (Fallback for docker-compose overrides)
export COMPOSE_PROJECT_NAME="${ENV_NAME}-${SITE_NAME}"
export NETWORK_NAME="${ENV_NAME}-net"

# 2. COLD START CHECK
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
    echo "[$SITE_NAME] 🚀 Cold start detected. Forcing initial build..."
    FORCE_UPDATE=1
fi

echo "[$SITE_NAME] 🔄 Checking for updates..."

# 3. GIT CONFIGURATION (Anti-Permission Errors)
sudo -u tis git config core.filemode false

# 4. GIT PULL & CONFLICT MANAGEMENT
LOCAL_COMMIT=$(git rev-parse HEAD)

echo "[$SITE_NAME] 📡 Fetching remote changes..."
sudo -u tis git fetch origin > /dev/null

# Check for potential conflicts
if ! sudo -u tis git merge-base --is-ancestor HEAD origin/main; then
    echo "[$SITE_NAME] ⚠️ CONFLICT DETECTED: Local changes would be overwritten."
    
    # Interactive prompt
    read -p "[$SITE_NAME] Do you want to FORCE the GitHub version (discards local changes)? [y/N]: " CONFIRM < /dev/tty
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "[$SITE_NAME] 💥 Forcing remote version (git reset --hard)..."
        sudo -u tis git reset --hard origin/main > /dev/null
    else
        echo "[$SITE_NAME] ❌ Update aborted by user to protect local changes."
        exit 1
    fi
else
    sudo -u tis git pull > /dev/null
fi

# 5. DOCKER DEPLOYMENT
echo "[$SITE_NAME] 🏗️ Processing containers (Network: $NETWORK_NAME)..."
docker compose up -d --build --force-recreate > /dev/null

echo "[$SITE_NAME] ✅ Pull & Rebuild complete."
