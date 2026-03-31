#!/bin/bash
# FILE: tis-web.sh
# Global CLI for TIS Web Infrastructure

set -e

# --- COLORS FOR TERMINAL ---
export BOLD='\033[1m'
export GREEN='\033[0;32m'
export CYAN='\033[0;36m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export RESET='\033[0m'

# --- 1. SCRIPT CONTEXT ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/tis-web-update.sh"
BASE_WEB_DIR="/home/tis/websites"
CORE_NAME="hosting-core"

GIT_HOST="github.com"
REPOSITORY_OWNER="TechITSimple"

# --- 2. HELP FUNCTION ---
show_help() {
    echo -e "${BOLD}${CYAN}TechITSimple Web Manager${RESET}"
    echo -e "Usage: ${GREEN}tis-web${RESET} <action> [environment] [site]"
    echo ""
    echo -e "${BOLD}ACTIONS:${RESET}"
    echo -e "  ${GREEN}create-env${RESET} <env>      Bootstrap a new environment (clones core, sets network)"
    echo -e "  ${GREEN}install${RESET} <site>        Clone and setup a new site repository"
    echo -e "  ${GREEN}update${RESET} [site]         Pull changes and restart container (defaults to current)"
    echo -e "  ${GREEN}update-all${RESET}            Update core infrastructure then all satellites"
    echo -e "  ${GREEN}status${RESET} [site]         Show container health (defaults to env-wide status)"
    echo -e "  ${GREEN}stop/start${RESET} <site>     Manage container lifecycle"
    echo -e "  ${GREEN}edit${RESET} <site>           Re-run interactive .env configuration"
    echo -e "  ${GREEN}remove${RESET} <site>         PERMANENTLY delete a site (containers, volumes, files)"
    echo ""
    echo -e "${BOLD}CONTEXT DETECTION:${RESET}"
    echo -e "  1. ${CYAN}Anywhere:${RESET}    tis-web <action> <env> <site>    (inside any path)"
    echo -e "  2. ${CYAN}Env Folder:${RESET}  tis-web <action> <site>          (inside e.g. /tis-test/)"
    echo -e "  3. ${CYAN}Site Folder:${RESET} tis-web <action>                 (inside e.g. /tis-test/my-site/)"
    echo ""
}

# --- 3. ARGUMENT PARSING & CONTEXT RESOLUTION ---
ACTION=$1
ENV_NAME=""
TARGET_SITE=""

# Show help if no arguments or help requested
if [[ -z "$ACTION" || "$ACTION" == "-h" || "$ACTION" == "--help" || "$ACTION" == "help" ]]; then
    show_help
    exit 0
fi

if [ "$ACTION" == "create-env" ]; then
    if [ -z "$2" ]; then
        echo -e "${RED}Error: Please provide an environment name.${RESET}"
        echo "Usage: tis-web create-env <environment-name>"
        echo "Example: tis-web create-env clients-prod"
        exit 1
    fi
    ENV_NAME=$2
    ENV_DIR="$BASE_WEB_DIR/$ENV_NAME"
else
    # Detect context dynamically to support env-level and site-level commands
    if [ "$#" -ge 2 ]; then
        if [ -d "$BASE_WEB_DIR/$2" ]; then
            # Execution from anywhere with env specified
            ENV_NAME=$2
            TARGET_SITE=$3
        else
            # Execution from within env folder
            ENV_NAME=$(basename "$PWD")
            TARGET_SITE=$2
        fi
    else
        # Execution with 1 argument
        if [ -d "$PWD/$CORE_NAME" ]; then
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

    # --- 4. VALIDATION ---
    if [ ! -d "$ENV_DIR" ]; then
        echo -e "${RED}Error: Environment '$ENV_NAME' not found.${RESET}"
        exit 1
    fi

    if [[ "$ACTION" =~ ^(install|edit|remove|start|stop)$ ]] && [ -z "$TARGET_SITE" ]; then
        echo -e "${RED}Error: Action '$ACTION' requires a specific target site.${RESET}"
        exit 1
    fi

    if [[ "$ACTION" != "install" && -n "$TARGET_SITE" && ! -d "$TARGET_DIR" ]]; then
        echo -e "${RED}Error: Site '$TARGET_SITE' does not exist in environment '$ENV_NAME'.${RESET}"
        exit 1
    fi
fi

# --- 5. CORE FUNCTIONS ---
build_env_interactively() {
    local target_dir=$1
    echo -e "${YELLOW}[Manager] Configuring environment variables for $TARGET_SITE${RESET}"
    
    if [ ! -f "$target_dir/template.env" ]; then
        echo -e "${CYAN}[Manager] No template.env found. Skipping configuration.${RESET}"
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
                echo -e "${CYAN}[Manager] Auto-linked $key -> $ref_key ($resolved_val)${RESET}"
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
        read -p "🔑 $key [$suggested_val]: " user_val < /dev/tty
        
        local final_val="${user_val:-$suggested_val}"
        echo "${key}=${final_val}" >> "$temp_env"
    done < "$target_dir/template.env"

    # --- AUTO-INJECT SYSTEM VARIABLES ---
    sed -i '/^NETWORK_NAME=/d' "$temp_env" 2>/dev/null || true
    sed -i '/^COMPOSE_PROJECT_NAME=/d' "$temp_env" 2>/dev/null || true

    echo "" >> "$temp_env"
    echo "# --- AUTO-GENERATED SYSTEM VARIABLES ---" >> "$temp_env"
    echo "NETWORK_NAME=${ENV_NAME}-net" >> "$temp_env"
    echo "COMPOSE_PROJECT_NAME=${TARGET_SITE}" >> "$temp_env"

    mv "$temp_env" "$target_dir/.env"
    echo -e "${GREEN}[Manager] .env file saved and system variables auto-injected successfully.${RESET}"
}

do_create_env() {
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}🏗️  BOOTSTRAPPING ENVIRONMENT: $ENV_NAME${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"

    if [ -d "$ENV_DIR" ]; then
        echo -e "${RED}Error: Directory $ENV_DIR already exists.${RESET}"
        exit 1
    fi

    echo -e "${CYAN}[Installer] 📁 Creating directory: $ENV_DIR${RESET}"
    mkdir -p "$ENV_DIR"

    # We set TARGET_SITE temporarily so the interactive builder knows what it's configuring
    TARGET_SITE="$CORE_NAME"
    TARGET_DIR="$ENV_DIR/$CORE_NAME"

    echo -e "${CYAN}[Installer] 📥 Cloning $CORE_NAME repository...${RESET}"
    cd "$ENV_DIR"
    sudo -u tis git clone "git@${GIT_HOST}:${REPOSITORY_OWNER}/${CORE_NAME}.git" "$CORE_NAME"

    echo -e "${CYAN}[Installer] 🔐 Applying permissions (tis:web-admins)...${RESET}"
    sudo chown -R tis:web-admins "$ENV_DIR"
    sudo chmod -R 775 "$ENV_DIR"
    sudo find "$ENV_DIR" -type d -exec chmod g+s {} +

    echo -e "${CYAN}[Installer] ⚙️  Setting up global configs...${RESET}"
    if [ -f "$TARGET_DIR/global.env" ]; then
        cp "$TARGET_DIR/global.env" "$ENV_DIR/.env"
    fi

    # Run the interactive builder for the core to prompt for TUNNEL_TOKEN etc.
    build_env_interactively "$TARGET_DIR"

    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}🚀 STARTING INITIAL DEPLOYMENT${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    do_update_all
}

do_install() {
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}INSTALLING: $TARGET_SITE in $ENV_NAME${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    
    cd "$ENV_DIR"
    sudo -u tis git clone "git@${GIT_HOST}:${REPOSITORY_OWNER}/${TARGET_SITE}.git" "$TARGET_SITE"
    
    sudo chown -R tis:web-admins "$TARGET_SITE"
    sudo chmod -R 775 "$TARGET_SITE"

    build_env_interactively "$TARGET_DIR"
    
    (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT" --force)
}

do_update_all() {
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}UPDATING ALL IN: $ENV_NAME${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    
    # 1. Force update core first to ensure network and tunnel stability
    if [ -d "$ENV_DIR/$CORE_NAME" ]; then
        echo -e "${CYAN}--> [1/2] Updating Core Infrastructure...${RESET}"
        (cd "$ENV_DIR/$CORE_NAME" && bash "$UPDATE_SCRIPT")
    else
        echo -e "${YELLOW}Warning: $CORE_NAME not found in $ENV_NAME${RESET}"
    fi

    echo -e "${CYAN}--> [2/2] Updating Satellites...${RESET}"
    for dir in "$ENV_DIR"/*/; do
        local dir_name=$(basename "$dir")
        if [ "$dir_name" != "$CORE_NAME" ] && [ -d "$dir" ]; then
            echo -e "    ${GREEN}-> Updating: $dir_name${RESET}"
            (cd "$dir" && bash "$UPDATE_SCRIPT")
        fi
    done
    
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${GREEN}All updates completed successfully.${RESET}"
}

do_status() {
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    if [ -n "$TARGET_SITE" ]; then
        echo -e "${BOLD}${YELLOW}STATUS FOR: $TARGET_SITE${RESET}"
        echo -e "${BOLD}${CYAN}=========================================${RESET}"
        (cd "$TARGET_DIR" && docker compose ps)
    else
        echo -e "${BOLD}${YELLOW}STATUS FOR ENVIRONMENT: $ENV_NAME${RESET}"
        echo -e "${BOLD}${CYAN}=========================================${RESET}"
        for dir in "$ENV_DIR"/*/; do
            if [ -f "$dir/docker-compose.yml" ]; then
                echo -e "${CYAN}--- $(basename "$dir") ---${RESET}"
                (cd "$dir" && docker compose ps)
                echo ""
            fi
        done
    fi
}

do_action() {
    local action=$1
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}EXECUTING '$action' ON: $TARGET_SITE${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    
    case "$action" in
        stop)
            (cd "$TARGET_DIR" && docker compose stop)
            echo -e "${GREEN}Containers stopped.${RESET}"
            ;;
        start)
            (cd "$TARGET_DIR" && docker compose start)
            echo -e "${GREEN}Containers started.${RESET}"
            ;;
        update)
            (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT")
            ;;
        edit)
            build_env_interactively "$TARGET_DIR"
            (cd "$TARGET_DIR" && bash "$UPDATE_SCRIPT" --force)
            ;;
        remove)
            echo -e "${RED}WARNING: You are about to PERMANENTLY remove '$TARGET_SITE'.${RESET}"
            read -p "Are you absolutely sure? [y/N]: " confirm < /dev/tty
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                (cd "$TARGET_DIR" && docker compose down -v)
                sudo rm -rf "$TARGET_DIR"
                echo -e "${GREEN}'$TARGET_SITE' removed successfully.${RESET}"
            else
                echo -e "${YELLOW}Aborted.${RESET}"
            fi
            ;;
    esac
}

# --- 6. ROUTER ---
case "$ACTION" in
    create-env) do_create_env ;;
    install)    do_install ;; 
    update-all) do_update_all ;;
    status)     do_status ;;
    edit|update|stop|start|remove) do_action "$ACTION" ;;
    *) 
        echo -e "${RED}Unknown command: $ACTION${RESET}"
        show_help
        exit 1 
        ;;
esac
