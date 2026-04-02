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
REAL_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$REAL_SCRIPT")
UPDATE_SCRIPT="$SCRIPT_DIR/tis-web-update.sh"
BASE_WEB_DIR="/home/tis/websites"
CORE_NAME="hosting-core"

GIT_HOST="github.com"
REPOSITORY_OWNER="TechITSimple"

# --- 2. HELP FUNCTION ---
show_help() {
    echo -e "${BOLD}${CYAN}TechITSimple Web Manager${RESET}"
    echo -e "Usage: ${GREEN}tis-web${RESET} <action> [environment] [sites... | -a]"
    echo ""
    echo -e "${BOLD}ACTIONS:${RESET}"
    echo -e "  ${GREEN}create-env${RESET} <env>             Bootstrap a new environment"
    echo -e "  ${GREEN}install${RESET} [env] <site>         Clone and setup ONE new site"
    echo -e "  ${GREEN}pull${RESET} [env] [sites...|-a]     Update site(s). Use -a or leave empty for all."
    echo -e "  ${GREEN}status${RESET} [env] [sites...|-a]   Show container health. Use -a or leave empty for all."
    echo -e "  ${GREEN}down/up${RESET} [env] [sites...|-a]  Manage container lifecycle. Use -a or leave empty for all."
    echo -e "  ${GREEN}edit${RESET} [env] <site>            Re-run interactive .env configuration for ONE site"
    echo -e "  ${GREEN}remove${RESET} [env] <site>          PERMANENTLY delete ONE site"
    echo ""
    echo -e "${BOLD}CONTEXT DETECTION:${RESET}"
    echo -e "  - ${CYAN}Root Folder:${RESET} If in $BASE_WEB_DIR, you MUST specify [env]"
    echo -e "  - ${CYAN}Env Folder:${RESET}  If inside /env/, [env] is automatic"
    echo -e "  - ${CYAN}Site Folder:${RESET} If inside /env/site/, both [env] and [site] are automatic"
    echo ""
}

# --- 3. ARGUMENT PARSING & CONTEXT RESOLUTION ---
ACTION=$1
ENV_NAME=""
TARGET_SITES=()

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
    # Detect context dynamically using shift to capture remaining args
    if [ "$PWD" == "$BASE_WEB_DIR" ]; then
        ENV_NAME=$2
        shift 2 || true
        TARGET_SITES=("$@")
    elif [ -d "$PWD/$CORE_NAME" ]; then
        ENV_NAME=$(basename "$PWD")
        shift 1 || true
        TARGET_SITES=("$@")
    elif [ -d "$(dirname "$PWD")/$CORE_NAME" ]; then
        ENV_NAME=$(basename "$(dirname "$PWD")")
        shift 1 || true
        # If inside a site folder but we pass args (like -a), respect them
        if [ ${#@} -gt 0 ]; then
            TARGET_SITES=("$@")
        else
            TARGET_SITES=($(basename "$PWD"))
        fi
    else
        ENV_NAME=$2
        shift 2 || true
        TARGET_SITES=("$@")
    fi

    ENV_DIR="$BASE_WEB_DIR/$ENV_NAME"

    # --- 4. VALIDATION ---
    if [ -z "$ENV_NAME" ] || [ ! -d "$ENV_DIR" ]; then
        echo -e "${RED}Error: Environment '$ENV_NAME' not found or not specified.${RESET}"
        exit 1
    fi

    BULK_MODE=false
    # Trigger bulk mode if empty, or if first arg is -a or *
    if [[ ${#TARGET_SITES[@]} -eq 0 || "${TARGET_SITES[0]}" == "-a" || "${TARGET_SITES[0]}" == "*" ]]; then
        BULK_MODE=true
    fi

    # Lock single-target actions
    if [[ "$ACTION" =~ ^(install|edit|remove)$ ]]; then
        if [ "$BULK_MODE" == true ]; then
            echo -e "${RED}Error: Action '$ACTION' requires a specific target site.${RESET}"
            exit 1
        fi
        if [ ${#TARGET_SITES[@]} -gt 1 ]; then
            echo -e "${RED}Error: Action '$ACTION' accepts only ONE target site at a time.${RESET}"
            exit 1
        fi
    fi

    # Validate existence of each requested site (skip for install)
    if [ "$BULK_MODE" == false ] && [ "$ACTION" != "install" ]; then
        for site in "${TARGET_SITES[@]}"; do
            if [ ! -d "$ENV_DIR/$site" ]; then
                echo -e "${RED}Error: Site '$site' does not exist in environment '$ENV_NAME'.${RESET}"
                exit 1
            fi
        done
    fi
fi

# --- 5. CORE FUNCTIONS ---
build_env_interactively() {
    local target_dir=$1
    local template_file=${2:-template.env}
    local is_global=${3:-false}
    
    local display_name=$TARGET_SITE
    [ "$is_global" == true ] && display_name="$ENV_NAME (Global)"

    echo -e "${YELLOW}[Manager] Configuring environment variables for $display_name${RESET}"
    
    if [ ! -f "$target_dir/$template_file" ]; then
        echo -e "${CYAN}[Manager] No $template_file found. Skipping configuration.${RESET}"
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
    done < "$target_dir/$template_file"

    # --- AUTO-INJECT SYSTEM VARIABLES (Skip for global) ---
    if [ "$is_global" == false ]; then
        sed -i '/^NETWORK_NAME=/d' "$temp_env" 2>/dev/null || true
        sed -i '/^COMPOSE_PROJECT_NAME=/d' "$temp_env" 2>/dev/null || true
        sed -i '/^ENV_NAME=/d' "$temp_env" 2>/dev/null || true

        echo "" >> "$temp_env"
        echo "# --- AUTO-GENERATED SYSTEM VARIABLES ---" >> "$temp_env"
        echo "ENV_NAME=${ENV_NAME}" >> "$temp_env"
        echo "NETWORK_NAME=${ENV_NAME}-net" >> "$temp_env"
        echo "COMPOSE_PROJECT_NAME=${ENV_NAME}-${TARGET_SITE}" >> "$temp_env"
    fi

    mv "$temp_env" "$target_dir/.env"
    echo -e "${GREEN}[Manager] .env file saved successfully.${RESET}"
}

do_bulk_action() {
    local act=$1
    
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}BULK ACTION: ${act^^} ON ALL IN $ENV_NAME${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"

    # --- STATUS OPTIMIZATION ---
    if [ "$act" == "status" ]; then
        # Use native Docker filter instead of looping directories
        docker ps -a --filter "name=${ENV_NAME}"
        echo -e "${BOLD}${CYAN}=========================================${RESET}"
        return 0
    fi

    local d_cmd=$act
    [ "$act" == "up" ] && d_cmd="up -d"

    # 1. Always process Core first
    if [ -d "$ENV_DIR/$CORE_NAME" ]; then
        echo -e "${CYAN}--- [CORE] $CORE_NAME ---${RESET}"
        (cd "$ENV_DIR/$CORE_NAME" && [ "$act" == "pull" ] && bash "$UPDATE_SCRIPT" || docker compose $d_cmd)
        echo ""
    else
        echo -e "${YELLOW}Warning: $CORE_NAME not found in $ENV_NAME${RESET}"
    fi

    # 2. Process all other satellites
    for dir in "$ENV_DIR"/*/; do
        local dname=$(basename "$dir")
        if [ "$dname" != "$CORE_NAME" ] && [ -d "$dir" ] && [ -f "${dir}docker-compose.yml" ]; then
            echo -e "${CYAN}--- $dname ---${RESET}"
            (cd "$dir" && [ "$act" == "pull" ] && bash "$UPDATE_SCRIPT" || docker compose $d_cmd)
            echo ""
        fi
    done
    
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${GREEN}Bulk $act completed successfully.${RESET}"
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

    # Temporarily target the core to configure it
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
        # Temporarily copy global.env to process it into the final .env
        cp "$TARGET_DIR/global.env" "$ENV_DIR/global.env"
        build_env_interactively "$ENV_DIR" "global.env" true
        rm "$ENV_DIR/global.env"
    fi

    # Configure the core site (template.env)
    build_env_interactively "$TARGET_DIR"

    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}🚀 STARTING INITIAL DEPLOYMENT${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    # Trigger bulk update to start the environment
    do_bulk_action "pull"
}

do_install() {
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}INSTALLING: $TARGET_SITE in $ENV_NAME${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    
    cd "$ENV_DIR"
    
    sudo -u tis git clone "git@${GIT_HOST}:${REPOSITORY_OWNER}/${TARGET_SITE}.git" "$TARGET_SITE"
    
    echo -e "${CYAN}[Manager] 🛡️  Disabling Git fileMode tracking...${RESET}"
    (cd "$TARGET_DIR" && sudo -u tis git config core.fileMode false)

    build_env_interactively "$TARGET_DIR"

    # HOOK: post-install (One-time setup)
    if [ -f "$TARGET_DIR/post-install.sh" ]; then
        echo -e "${CYAN}[Manager] 🪝  Executing post-install hook...${RESET}"
        chmod +x "$TARGET_DIR/post-install.sh"
        (cd "$TARGET_DIR" && bash "post-install.sh")
    fi

    # Initial permission fix before first run
    sudo chown -R tis:web-admins "$TARGET_SITE"
    sudo chmod -R 775 "$TARGET_SITE"

    # First launch
    do_action "pull"
}

do_action() {
    local action=$1
    local d_cmd=$action
    [ "$action" == "status" ] && d_cmd="ps"
    [ "$action" == "up" ] && d_cmd="up -d"

    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${YELLOW}EXECUTING '$action' ON: $TARGET_SITE${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    
    case "$action" in
        down|up|status)
            (cd "$TARGET_DIR" && docker compose $d_cmd)
            [ "$action" != "status" ] && echo -e "${GREEN}Containers ${action} applied.${RESET}"
            ;;
        pull)
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
    install|edit|remove)
        # We know from validation that TARGET_SITES has exactly 1 element here
        TARGET_SITE=${TARGET_SITES[0]}
        TARGET_DIR="$ENV_DIR/$TARGET_SITE"
        if [ "$ACTION" == "install" ]; then
            do_install
        else
            do_action "$ACTION"
        fi
        ;;
    status|pull|down|up)
        if [ "$BULK_MODE" == true ]; then
            do_bulk_action "$ACTION"
        else
            for site in "${TARGET_SITES[@]}"; do
                TARGET_SITE=$site
                TARGET_DIR="$ENV_DIR/$TARGET_SITE"
                do_action "$ACTION"
            done
        fi
        ;;
    *) 
        echo -e "${RED}Unknown command: $ACTION${RESET}"
        show_help
        exit 1 
        ;;
esac
