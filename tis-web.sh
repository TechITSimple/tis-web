#!/bin/bash
# FILE: tis-web.sh
# Global CLI for TIS Web Infrastructure

set -e

# --- 1. SCRIPT CONTEXT ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/tis-web-update.sh"
BASE_WEB_DIR="/home/tis/websites"

# --- 2. ARGUMENT PARSING & CONTEXT RESOLUTION ---
ACTION=$1
ENV_NAME=""
TARGET_SITE=""

# Detect context dynamically to support env-level and site-level commands
if [ "$#" -ge 2 ]; then
    if [ -d "$BASE_WEB_DIR/$2" ]; then
        # Execution from anywhere with env specified (e.g., tis-web status tis-test [site])
        ENV_NAME=$2
        TARGET_SITE=$3
    else
        # Execution from within env folder (e.g., tis-web update sideros-website)
        ENV_NAME=$(basename "$PWD")
        TARGET_SITE=$2
    fi
else
    # Execution with 1 argument (e.g., tis-web status)
    if [ -d "$PWD/hosting-core" ]; then
        # Inside env folder
        ENV_NAME=$(basename "$PWD")
    else
        # Inside site folder
        ENV_NAME=$(basename "$(dirname "$PWD")")
        TARGET_SITE=$(basename "$PWD")
    fi
fi

ENV_DIR="$BASE_WEB_DIR/$ENV_NAME"
TARGET_DIR="$ENV_DIR/$TARGET_SITE"

# --- 3. VALIDATION ---
if [ ! -d "$ENV_DIR" ]; then
    echo "Error: Environment '$ENV_NAME' not found."
    exit 1
fi

if [[ "$ACTION" =~ ^(install|edit|remove|start|stop)$ ]] && [ -z "$TARGET_SITE" ]; then
    echo "Error: Action '$ACTION' requires a specific target site."
    exit 1
fi

if [[ "$ACTION" != "install" && -n "$TARGET_SITE" && ! -d "$TARGET_DIR" ]]; then
    echo "Error: Site '$TARGET_SITE' does not exist in environment '$ENV_NAME'."
    exit 1
fi

# --- 4. CORE FUNCTIONS ---
build_env_interactively() {
    local target_dir=$1
    echo "[Manager] Configuring environment variables for $TARGET_SITE"
    
    if [ ! -f "$target_dir/template.env" ]; then
        echo "[Manager] No template.env found. Skipping configuration."
        return
    fi

    local temp_env="$target_dir/.env.tmp"
    > "$temp_env"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            echo "$line" >> "$temp_env"
            continue
        fi

        local key=$(echo "$line" | cut -d '=' -f 1)
        local default_val=$(echo "$line" | cut -d '=' -f 2- || true)
        
        # --- AUTO-RESOLVE LOGIC ---
        if [[ "$default_val" == \$* ]]; then
            local ref_key=${default_val#$}
            local resolved_val=$(grep "^${ref_key}=" "$temp_env" | cut -d '=' -f 2- || true)
            
            if [ -n "$resolved_val" ]; then
                echo "[Manager] Auto-linked $key -> $ref_key ($resolved_val)"
                echo "${key}=${resolved_val}" >> "$temp_env"
                continue
            fi
        fi

        local current_val=""
        if [ -f "$target_dir/.env" ]; then
            current_val=$(grep "^${key}=" "$target_dir/.env" | cut -d '=' -f 2- || true)
        fi

        local suggested_val="${current_val:-$default_val}"
        local user_val=""
        read -p "$key [$suggested_val]: " user_val < /dev/tty
        
        local final_val="${user_val:-$suggested_val}"
        echo "${key}=${final_val}" >> "$temp_env"
    done < "$target_dir/template.env"

    # --- AUTO-INJECT SYSTEM VARIABLES ---
    # Remove any existing definitions to prevent duplicates
    sed -i '/^NETWORK_NAME=/d' "$temp_env" 2>/dev/null || true
    sed -i '/^COMPOSE_PROJECT_NAME=/d' "$temp_env" 2>/dev/null || true

    # Append dynamic variables based on current context
    echo "" >> "$temp_env"
    echo "# --- AUTO-GENERATED SYSTEM VARIABLES ---" >> "$temp_env"
    echo "NETWORK_NAME=${ENV_NAME}-net" >> "$temp_env"
    echo "COMPOSE_PROJECT_NAME=${TARGET_SITE}" >> "$temp_env"

    mv "$temp_env" "$target_dir/.env"
    echo "[Manager] .env file saved and system variables auto-injected successfully."
}

do_install() {
    echo "========================================="
    echo "INSTALLING: $TARGET_SITE in $ENV_NAME"
    echo "========================================="
    
    cd "$ENV_DIR"
    sudo -u tis git clone "git@github.com:TechITSimple/${TARGET_SITE}.git" "$TARGET_SITE"
    
    sudo chown -R tis:web-admins "$TARGET_SITE"
    sudo chmod -R 775 "$TARGET_SITE"

    build_env_interactively "$TARGET_DIR"
    
    (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT" --force)
}

do_update_all() {
    echo "========================================="
    echo "UPDATING ALL IN: $ENV_NAME"
    echo "========================================="
    
    # 1. Force update hosting-core first to ensure network and tunnel stability
    if [ -d "$ENV_DIR/hosting-core" ]; then
        echo "--> [1/2] Updating Core Infrastructure..."
        (cd "$ENV_DIR/hosting-core" && bash "$UPDATE_SCRIPT")
    else
        echo "Warning: hosting-core not found in $ENV_NAME"
    fi

    echo "--> [2/2] Updating Satellites..."
    # 2. Iterate and update all other satellite directories
    for dir in "$ENV_DIR"/*/; do
        local dir_name=$(basename "$dir")
        if [ "$dir_name" != "hosting-core" ] && [ -d "$dir" ]; then
            echo "    -> Updating: $dir_name"
            (cd "$dir" && bash "$UPDATE_SCRIPT")
        fi
    done
    
    echo "========================================="
    echo "All updates completed successfully."
}

do_status() {
    echo "========================================="
    if [ -n "$TARGET_SITE" ]; then
        echo "STATUS FOR: $TARGET_SITE"
        echo "========================================="
        (cd "$TARGET_DIR" && docker compose ps)
    else
        echo "STATUS FOR ENVIRONMENT: $ENV_NAME"
        echo "========================================="
        for dir in "$ENV_DIR"/*/; do
            if [ -f "$dir/docker-compose.yml" ]; then
                echo "--- $(basename "$dir") ---"
                (cd "$dir" && docker compose ps)
                echo ""
            fi
        done
    fi
}

do_action() {
    local action=$1
    echo "========================================="
    echo "EXECUTING '$action' ON: $TARGET_SITE"
    echo "========================================="
    
    case "$action" in
        stop)
            (cd "$TARGET_DIR" && docker compose stop)
            echo "Containers stopped."
            ;;
        start)
            (cd "$TARGET_DIR" && docker compose start)
            echo "Containers started."
            ;;
        update)
            (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT")
            ;;
        edit)
            build_env_interactively "$TARGET_DIR"
            (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT" --force)
            ;;
        remove)
            echo "WARNING: You are about to PERMANENTLY remove '$TARGET_SITE'."
            read -p "Are you absolutely sure? [y/N]: " confirm < /dev/tty
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                (cd "$TARGET_DIR" && docker compose down -v)
                sudo rm -rf "$TARGET_DIR"
                echo "'$TARGET_SITE' removed successfully."
            else
                echo "Aborted."
            fi
            ;;
    esac
}

# --- 5. ROUTER ---
case "$ACTION" in
    install)    do_install ;; 
    update-all) do_update_all ;;
    status)     do_status ;;
    edit|update|stop|start|remove) do_action "$ACTION" ;;
    *) 
        echo "Unknown command: $ACTION"
        echo "Available: install, update, update-all, edit, stop, start, remove, status"
        exit 1 
        ;;
esac
