#!/usr/bin/env bash
# deploy-openclaw.sh — Interactive TUI wizard for deploying OpenClaw on Ubuntu/Debian VPS
# Usage: curl -fsSL https://raw.githubusercontent.com/PhucMPham/deploy-openclaw/main/scripts/deploy-openclaw.sh | bash
# Or:    bash deploy-openclaw.sh
# shellcheck disable=SC2059  # Intentional: color vars in printf format strings
# shellcheck disable=SC2015  # Intentional: A && B || C where B always succeeds (print_status)
set -euo pipefail

# ============================================================================
# SECTION A: Constants & Globals
# ============================================================================

readonly VERSION="1.0.0"
readonly OPENCLAW_USER="openclaw"
readonly OPENCLAW_HOME="/opt/openclaw"
readonly STATE_FILE="${OPENCLAW_HOME}/.deploy-state"
readonly LOG_FILE="${OPENCLAW_HOME}/deploy.log"
readonly MIN_NODE_MAJOR=22
readonly MIN_DISK_MB=2048

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Rollback stack
declare -a ROLLBACK_STACK=()

# ============================================================================
# SECTION B: TUI Components
# ============================================================================

# Read a single keypress, handling escape sequences for arrow keys
# Returns: "up", "down", "enter", "space", or the character itself
read_key() {
    local key
    IFS= read -rsn1 key
    case "$key" in
        $'\x1b')
            read -rsn2 -t 0.1 key || true
            case "$key" in
                '[A') echo "up" ;;
                '[B') echo "down" ;;
                *)    echo "escape" ;;
            esac
            ;;
        '') echo "enter" ;;
        ' ') echo "space" ;;
        *) echo "$key" ;;
    esac
}

# Arrow-key vertical menu. Returns selected index (0-based) in TUI_RESULT.
# Usage: tui_menu "Pick one:" "Option A" "Option B" "Option C"
tui_menu() {
    local prompt="$1"; shift
    local -a options=("$@")
    local count=${#options[@]}
    local selected=0
    local i

    # Hide cursor
    tput civis 2>/dev/null || true

    while true; do
        # Move cursor up to redraw (except first draw)
        printf "\r"
        # Clear and print prompt
        printf "\033[J"
        printf "${BOLD}%s${NC}\n" "$prompt"
        for ((i = 0; i < count; i++)); do
            if ((i == selected)); then
                printf "  ${CYAN}> %s${NC}\n" "${options[$i]}"
            else
                printf "    ${DIM}%s${NC}\n" "${options[$i]}"
            fi
        done

        local key
        key=$(read_key)
        case "$key" in
            up)    ((selected > 0)) && ((selected--)) ;;
            down)  ((selected < count - 1)) && ((selected++)) ;;
            enter) break ;;
        esac

        # Move cursor back up to redraw
        printf "\033[%dA" $((count + 1))
    done

    # Show cursor
    tput cnorm 2>/dev/null || true
    TUI_RESULT=$selected
}

# Multi-select checkbox menu. Returns space-separated indices in TUI_RESULT.
# Usage: tui_checkbox "Select items:" "on:UFW Firewall" "on:SSH Keys" "off:SSH Hardening"
tui_checkbox() {
    local prompt="$1"; shift
    local -a labels=()
    local -a states=()
    local i

    for item in "$@"; do
        local prefix="${item%%:*}"
        local label="${item#*:}"
        labels+=("$label")
        if [[ "$prefix" == "on" ]]; then
            states+=(1)
        else
            states+=(0)
        fi
    done

    local count=${#labels[@]}
    local selected=0

    tput civis 2>/dev/null || true

    while true; do
        printf "\r\033[J"
        printf "${BOLD}%s${NC} ${DIM}(SPACE=toggle, ENTER=confirm)${NC}\n" "$prompt"
        for ((i = 0; i < count; i++)); do
            local check=" "
            ((states[i])) && check="x"
            if ((i == selected)); then
                printf "  ${CYAN}> [%s] %s${NC}\n" "$check" "${labels[$i]}"
            else
                printf "    [%s] ${DIM}%s${NC}\n" "$check" "${labels[$i]}"
            fi
        done

        local key
        key=$(read_key)
        case "$key" in
            up)    ((selected > 0)) && ((selected--)) ;;
            down)  ((selected < count - 1)) && ((selected++)) ;;
            space) ((states[selected] = !states[selected])) ;;
            enter) break ;;
        esac

        printf "\033[%dA" $((count + 1))
    done

    tput cnorm 2>/dev/null || true

    # Build result: space-separated indices of selected items
    TUI_RESULT=""
    for ((i = 0; i < count; i++)); do
        ((states[i])) && TUI_RESULT+="$i "
    done
    TUI_RESULT="${TUI_RESULT% }"
}

# Text input with optional default and secret mode.
# Usage: tui_input "Enter value:" "default" [true for secret]
tui_input() {
    local prompt="$1"
    local default="${2:-}"
    local is_secret="${3:-false}"

    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${NC}"

    printf "${BOLD}%s${NC}%b " "$prompt" "$display_default"

    local value
    if [[ "$is_secret" == "true" ]]; then
        read -rs value
        echo
    else
        read -r value
    fi

    [[ -z "$value" && -n "$default" ]] && value="$default"
    TUI_RESULT="$value"
}

# Yes/No confirmation with arrow selection. Returns 0=yes, 1=no.
tui_confirm() {
    local question="$1"
    tui_menu "$question" "Yes" "No"
    return "$TUI_RESULT"
}

# Spinner displayed while a background command runs.
# Usage: some_command & tui_spinner $! "Installing..."
tui_spinner() {
    local pid="$1"
    local label="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC} %s" "${frames[$((i % ${#frames[@]}))]}" "$label"
        ((i++))
        sleep 0.1
    done

    wait "$pid" 2>/dev/null
    local exit_code=$?
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true
    return "$exit_code"
}

# Print colored status line
print_status() {
    local type="$1"; shift
    local msg="$*"
    case "$type" in
        ok)   printf "  ${GREEN}✓${NC} %s\n" "$msg" ;;
        warn) printf "  ${YELLOW}⚠${NC} %s\n" "$msg" ;;
        fail) printf "  ${RED}✗${NC} %s\n" "$msg" ;;
        info) printf "  ${BLUE}ℹ${NC} %s\n" "$msg" ;;
    esac
}

# ASCII art banner
print_banner() {
    printf "${CYAN}"
    cat << 'BANNER'
   ___                    ____ _
  / _ \ _ __   ___ _ __  / ___| | __ ___      __
 | | | | '_ \ / _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|          Deploy Wizard
BANNER
    printf "${NC}\n"
    printf "  ${DIM}Version %s | %s | %s${NC}\n\n" "$VERSION" "$(uname -s)" "$(date '+%Y-%m-%d %H:%M')"
}

# ============================================================================
# SECTION C: State Persistence
# ============================================================================

state_init() {
    if [[ ! -d "$OPENCLAW_HOME" ]]; then
        run_with_sudo "mkdir -p $OPENCLAW_HOME"
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        run_with_sudo "touch $STATE_FILE"
        run_with_sudo "chmod 666 $STATE_FILE"
    fi
}

state_load() {
    # shellcheck disable=SC1090
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
}

state_save() {
    local key="$1" val="$2"
    # Remove existing key, then append
    if [[ -f "$STATE_FILE" ]]; then
        local tmp
        tmp=$(grep -v "^${key}=" "$STATE_FILE" 2>/dev/null || true)
        printf '%s\n' "$tmp" > "$STATE_FILE"
    fi
    printf '%s="%s"\n' "$key" "$val" >> "$STATE_FILE"
}

state_get() {
    local key="$1"
    local val=""
    if [[ -f "$STATE_FILE" ]]; then
        val=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d'"' -f2 || true)
    fi
    echo "$val"
}

state_show_summary() {
    printf "\n${BOLD}  Deployment Status${NC}\n"
    printf "  ─────────────────────────────────\n"
    local phases=("system_check:System Check" "user_setup:User Setup" "security_setup:Security Setup" "software_install:Software Install" "openclaw_setup:OpenClaw Setup")
    local num=1
    for entry in "${phases[@]}"; do
        local key="${entry%%:*}"
        local label="${entry#*:}"
        local status
        status=$(state_get "phase_${key}")
        local icon="${DIM}○${NC}"
        [[ "$status" == "done" ]] && icon="${GREEN}●${NC}"
        [[ "$status" == "partial" ]] && icon="${YELLOW}◐${NC}"
        printf "  %b Phase %d: %s\n" "$icon" "$num" "$label"
        ((num++))
    done
    printf "  ─────────────────────────────────\n\n"
}

# ============================================================================
# SECTION D: System Detection
# ============================================================================

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_status fail "Cannot detect OS: /etc/os-release not found"
        return 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_NAME="${PRETTY_NAME:-Unknown}"

    case "$OS_ID" in
        ubuntu)
            if ! awk 'BEGIN{exit !('"$OS_VERSION"' >= 22.04)}'; then
                print_status fail "Ubuntu $OS_VERSION detected. Minimum: 22.04"
                return 1
            fi
            ;;
        debian)
            if ((${OS_VERSION%%.*} < 11)); then
                print_status fail "Debian $OS_VERSION detected. Minimum: 11"
                return 1
            fi
            ;;
        *)
            print_status warn "Untested OS: $OS_NAME. Proceed with caution."
            ;;
    esac
    print_status ok "OS: $OS_NAME"
}

detect_user() {
    CURRENT_USER=$(whoami)
    IS_ROOT=false
    HAS_SUDO=false

    [[ "$CURRENT_USER" == "root" ]] && IS_ROOT=true
    if ! $IS_ROOT && sudo -n true 2>/dev/null; then
        HAS_SUDO=true
    fi

    if $IS_ROOT; then
        print_status ok "Running as root"
    elif $HAS_SUDO; then
        print_status ok "Running as $CURRENT_USER (sudo available)"
    else
        print_status warn "Running as $CURRENT_USER (no passwordless sudo — will prompt as needed)"
    fi
}

check_internet() {
    if curl -sfSL --max-time 5 https://openclaw.bot > /dev/null 2>&1; then
        print_status ok "Internet connectivity OK"
    else
        print_status fail "Cannot reach openclaw.bot — check internet"
        return 1
    fi
}

check_disk_space() {
    local avail_mb
    avail_mb=$(df -m / | awk 'NR==2{print $4}')
    if ((avail_mb < MIN_DISK_MB)); then
        print_status fail "Disk space: ${avail_mb}MB available (need ${MIN_DISK_MB}MB)"
        return 1
    fi
    print_status ok "Disk space: ${avail_mb}MB available"
}

check_existing_software() {
    HAS_NODE=false; NODE_VER=""
    HAS_NVM=false
    HAS_DOCKER=false
    HAS_OPENCLAW=false; OPENCLAW_VER=""
    HAS_UFW=false
    HAS_FAIL2BAN=false
    HAS_TAILSCALE=false

    # Node.js
    if command -v node &>/dev/null; then
        HAS_NODE=true
        NODE_VER=$(node -v 2>/dev/null | sed 's/^v//')
    fi
    # NVM
    if [[ -d "${HOME}/.nvm" ]] || [[ -d "/home/${OPENCLAW_USER}/.nvm" ]]; then
        HAS_NVM=true
    fi
    # Docker
    if command -v docker &>/dev/null; then
        HAS_DOCKER=true
    fi
    # OpenClaw
    load_nvm_silent
    if command -v openclaw &>/dev/null; then
        HAS_OPENCLAW=true
        OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    fi
    # Security tools
    command -v ufw &>/dev/null && HAS_UFW=true
    command -v fail2ban-client &>/dev/null && HAS_FAIL2BAN=true
    command -v tailscale &>/dev/null && HAS_TAILSCALE=true

    printf "\n  ${BOLD}Existing Software${NC}\n"
    [[ "$HAS_NODE" == true ]]      && print_status ok "Node.js $NODE_VER" || print_status info "Node.js not found"
    [[ "$HAS_NVM" == true ]]       && print_status ok "NVM installed"     || print_status info "NVM not found"
    [[ "$HAS_DOCKER" == true ]]    && print_status ok "Docker installed"  || print_status info "Docker not found"
    [[ "$HAS_OPENCLAW" == true ]]  && print_status ok "OpenClaw $OPENCLAW_VER" || print_status info "OpenClaw not found"
    [[ "$HAS_UFW" == true ]]       && print_status ok "UFW installed"     || print_status info "UFW not found"
    [[ "$HAS_FAIL2BAN" == true ]]  && print_status ok "fail2ban installed" || print_status info "fail2ban not found"
    [[ "$HAS_TAILSCALE" == true ]] && print_status ok "Tailscale installed" || print_status info "Tailscale not found"
}

# Run command with appropriate privilege escalation
run_with_sudo() {
    local cmd="$*"
    if $IS_ROOT; then
        eval "$cmd"
    elif $HAS_SUDO || sudo -n true 2>/dev/null; then
        sudo bash -c "$cmd"
    else
        printf "\n  ${YELLOW}This command requires root privileges:${NC}\n"
        printf "  ${DIM}%s${NC}\n" "$cmd"
        printf "  Run it manually, then press ENTER to continue..."
        read -r
    fi
}

# Detect pipe mode and re-exec with tty
ensure_not_piped() {
    if [[ ! -t 0 ]]; then
        local tmp_script="/tmp/deploy-openclaw-$$.sh"
        cat > "$tmp_script"
        chmod +x "$tmp_script"
        printf "Detected pipe mode. Re-launching with interactive terminal...\n"
        exec bash "$tmp_script" "$@" < /dev/tty
    fi
}

# Silently try to load NVM for openclaw user or current user
load_nvm_silent() {
    local nvm_dir="${NVM_DIR:-}"
    [[ -z "$nvm_dir" && -d "$HOME/.nvm" ]] && nvm_dir="$HOME/.nvm"
    [[ -z "$nvm_dir" && -d "/home/${OPENCLAW_USER}/.nvm" ]] && nvm_dir="/home/${OPENCLAW_USER}/.nvm"
    if [[ -n "$nvm_dir" && -s "${nvm_dir}/nvm.sh" ]]; then
        export NVM_DIR="$nvm_dir"
        # shellcheck disable=SC1091
        source "${nvm_dir}/nvm.sh" 2>/dev/null || true
    fi
}

# ============================================================================
# SECTION E: Phase Functions
# ============================================================================

# ---------- Phase 1: System Check ----------
phase_system_check() {
    printf "\n${BOLD}═══ Phase 1: System Check ═══${NC}\n\n"

    detect_os || return 1
    detect_user
    check_internet || return 1
    check_disk_space || return 1
    check_existing_software

    state_save "phase_system_check" "done"
    printf "\n"
    print_status ok "System check complete"
}

# ---------- Phase 2: User Setup ----------
phase_user_setup() {
    printf "\n${BOLD}═══ Phase 2: User Setup ═══${NC}\n\n"

    # Create openclaw user if not exists
    if id "$OPENCLAW_USER" &>/dev/null; then
        print_status ok "User '$OPENCLAW_USER' already exists"
    else
        print_status info "Creating user '$OPENCLAW_USER'..."
        run_with_sudo "useradd -m -s /bin/bash $OPENCLAW_USER"
        print_status ok "User '$OPENCLAW_USER' created"
    fi

    # Add to docker group (create group if needed)
    if getent group docker &>/dev/null; then
        if id -nG "$OPENCLAW_USER" 2>/dev/null | grep -qw docker; then
            print_status ok "'$OPENCLAW_USER' already in docker group"
        else
            run_with_sudo "usermod -aG docker $OPENCLAW_USER"
            print_status ok "Added '$OPENCLAW_USER' to docker group"
        fi
    else
        print_status info "Docker group doesn't exist yet (will be created with Docker install)"
    fi

    # Create workspace
    if [[ -d "$OPENCLAW_HOME" ]]; then
        print_status ok "Workspace $OPENCLAW_HOME exists"
    else
        run_with_sudo "mkdir -p $OPENCLAW_HOME"
        print_status ok "Created $OPENCLAW_HOME"
    fi
    run_with_sudo "chown -R ${OPENCLAW_USER}:${OPENCLAW_USER} ${OPENCLAW_HOME}"

    # Create .env template if not exists
    local env_file="${OPENCLAW_HOME}/.env"
    if [[ ! -f "$env_file" ]]; then
        run_with_sudo "touch $env_file && chmod 600 $env_file && chown ${OPENCLAW_USER}:${OPENCLAW_USER} $env_file"
        print_status ok "Created $env_file (chmod 600)"
    else
        print_status ok "$env_file already exists"
    fi

    state_save "phase_user_setup" "done"
    printf "\n"
    print_status ok "User setup complete"
}

# ---------- Phase 3: Security Setup ----------
phase_security_setup() {
    printf "\n${BOLD}═══ Phase 3: Security Setup ═══${NC}\n\n"

    tui_checkbox "Select security components to configure:" \
        "on:UFW Firewall" \
        "on:SSH Key Setup (guided)" \
        "off:SSH Hardening (disable password login)" \
        "on:fail2ban" \
        "off:Tailscale VPN"

    local selected="$TUI_RESULT"
    [[ -z "$selected" ]] && { print_status warn "No security components selected"; return 0; }

    # Parse selections
    local do_ufw=false do_sshkeys=false do_sshharden=false do_fail2ban=false do_tailscale=false
    for idx in $selected; do
        case "$idx" in
            0) do_ufw=true ;;
            1) do_sshkeys=true ;;
            2) do_sshharden=true ;;
            3) do_fail2ban=true ;;
            4) do_tailscale=true ;;
        esac
    done

    # --- UFW ---
    if $do_ufw; then
        printf "\n  ${BOLD}UFW Firewall${NC}\n"
        run_with_sudo "apt-get update -qq && apt-get install -y -qq ufw" &>/dev/null &
        tui_spinner $! "Installing UFW..." || true

        run_with_sudo "ufw default deny incoming"
        run_with_sudo "ufw default allow outgoing"
        run_with_sudo "ufw allow ssh"
        run_with_sudo "ufw allow 80/tcp"
        run_with_sudo "ufw allow 443/tcp"
        run_with_sudo "ufw --force enable"
        print_status ok "UFW configured: deny incoming, allow SSH/80/443"
    fi

    # --- SSH Key Setup ---
    if $do_sshkeys; then
        printf "\n  ${BOLD}SSH Key Setup${NC}\n"
        print_status info "To set up SSH key access, run this from your LOCAL machine:"
        printf "\n    ${CYAN}ssh-copy-id root@<server-ip>${NC}\n"
        printf "    ${DIM}(or: ssh-copy-id %s@<server-ip>)${NC}\n\n" "$OPENCLAW_USER"
        print_status info "After copying your key, test login in a NEW terminal before continuing."

        printf "\n"
        tui_menu "Have you set up and tested SSH key login?" \
            "Yes, SSH key login works" \
            "Skip for now"

        if ((TUI_RESULT == 0)); then
            state_save "ssh_keys_verified" "true"
            print_status ok "SSH key login confirmed"
        else
            state_save "ssh_keys_verified" "false"
            print_status warn "SSH keys not verified — SSH hardening will be blocked"
        fi
    fi

    # --- SSH Hardening ---
    if $do_sshharden; then
        printf "\n  ${BOLD}SSH Hardening${NC}\n"

        local keys_verified
        keys_verified=$(state_get "ssh_keys_verified")
        if [[ "$keys_verified" != "true" ]]; then
            print_status fail "REFUSED: SSH keys must be verified before hardening!"
            print_status info "Run SSH Key Setup first, verify key login, then retry."
        else
            print_status warn "This will disable password login and restrict root to key-only."
            printf "\n"
            print_status warn "Make sure you have VNC/console access as a fallback!"

            tui_menu "Proceed with SSH hardening?" "Yes, I have console access as backup" "No, skip this"

            if ((TUI_RESULT == 0)); then
                # Backup sshd_config
                local sshd_conf="/etc/ssh/sshd_config"
                local backup
                backup="${sshd_conf}.bak.$(date +%Y%m%d%H%M%S)"
                run_with_sudo "cp $sshd_conf $backup"
                ROLLBACK_STACK+=("cp $backup $sshd_conf && systemctl reload sshd")
                print_status ok "Backed up sshd_config → $backup"

                # Apply hardening
                run_with_sudo "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' $sshd_conf"
                run_with_sudo "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' $sshd_conf"

                # Test config before reload
                if run_with_sudo "sshd -t" 2>/dev/null; then
                    run_with_sudo "systemctl reload sshd"
                    print_status ok "SSH hardened: password auth disabled, root key-only"
                else
                    print_status fail "sshd config test failed! Rolling back..."
                    run_with_sudo "cp $backup $sshd_conf"
                    print_status ok "Rolled back to previous sshd_config"
                fi
            else
                print_status info "SSH hardening skipped"
            fi
        fi
    fi

    # --- fail2ban ---
    if $do_fail2ban; then
        printf "\n  ${BOLD}fail2ban${NC}\n"
        run_with_sudo "apt-get update -qq && apt-get install -y -qq fail2ban" &>/dev/null &
        tui_spinner $! "Installing fail2ban..." || true
        run_with_sudo "systemctl enable fail2ban && systemctl start fail2ban"
        print_status ok "fail2ban installed and enabled"
    fi

    # --- Tailscale ---
    if $do_tailscale; then
        printf "\n  ${BOLD}Tailscale VPN${NC}\n"
        if ! command -v tailscale &>/dev/null; then
            run_with_sudo "curl -fsSL https://tailscale.com/install.sh | sh" &>/dev/null &
            tui_spinner $! "Installing Tailscale..." || true
        fi
        print_status info "Run 'tailscale up' to authenticate with your Tailscale account."
        print_status info "After connecting, you can optionally restrict SSH to Tailscale only:"
        printf "    ${DIM}ufw allow from 100.64.0.0/10 to any port 22${NC}\n"
        printf "    ${DIM}ufw delete allow ssh${NC}\n"

        tui_menu "Run 'tailscale up' now?" "Yes" "I'll do it later"
        if ((TUI_RESULT == 0)); then
            run_with_sudo "tailscale up"
        fi
    fi

    state_save "phase_security_setup" "done"
    printf "\n"
    print_status ok "Security setup complete"
}

# ---------- Phase 4: Software Installation ----------
phase_software_install() {
    printf "\n${BOLD}═══ Phase 4: Software Installation ═══${NC}\n\n"

    # --- Docker ---
    if command -v docker &>/dev/null; then
        print_status ok "Docker already installed: $(docker --version 2>/dev/null | head -1)"
    else
        print_status info "Installing Docker CE..."
        run_with_sudo "apt-get update -qq" &>/dev/null
        run_with_sudo "apt-get install -y -qq ca-certificates curl gnupg" &>/dev/null

        run_with_sudo "install -m 0755 -d /etc/apt/keyrings"

        # Detect distro for Docker repo
        # shellcheck disable=SC1091
        source /etc/os-release
        local docker_url="https://download.docker.com/linux/${ID}"
        run_with_sudo "curl -fsSL ${docker_url}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" 2>/dev/null
        run_with_sudo "chmod a+r /etc/apt/keyrings/docker.gpg"

        local arch
        arch=$(dpkg --print-architecture)
        run_with_sudo "echo \"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] ${docker_url} ${VERSION_CODENAME} stable\" > /etc/apt/sources.list.d/docker.list"

        run_with_sudo "apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" &>/dev/null &
        tui_spinner $! "Installing Docker CE..." || {
            print_status fail "Docker installation failed. Check $LOG_FILE"
            return 1
        }

        # Add openclaw user to docker group
        if id "$OPENCLAW_USER" &>/dev/null; then
            run_with_sudo "usermod -aG docker $OPENCLAW_USER"
        fi
        print_status ok "Docker CE installed"
    fi

    # --- NVM + Node.js ---
    local target_user="$OPENCLAW_USER"
    local target_home
    target_home=$(eval echo "~${target_user}")
    local nvm_dir="${target_home}/.nvm"

    # Install NVM if not present for target user
    if [[ ! -d "$nvm_dir" ]]; then
        print_status info "Installing NVM for $target_user..."
        local nvm_install_cmd="curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
        if [[ "$CURRENT_USER" == "$target_user" ]]; then
            bash -c "$nvm_install_cmd" &>/dev/null &
            tui_spinner $! "Installing NVM..." || true
        else
            run_with_sudo "su - $target_user -c '$nvm_install_cmd'" &>/dev/null &
            tui_spinner $! "Installing NVM..." || true
        fi
        print_status ok "NVM installed"
    else
        print_status ok "NVM already installed at $nvm_dir"
    fi

    # Install Node.js via NVM
    local node_install_cmd="export NVM_DIR=\"${nvm_dir}\" && . \"\${NVM_DIR}/nvm.sh\" && nvm install 24 && nvm alias default 24"
    local current_node_major=0

    # Check current node version
    if [[ "$CURRENT_USER" == "$target_user" ]]; then
        export NVM_DIR="$nvm_dir"
        # shellcheck disable=SC1091
        [[ -s "${nvm_dir}/nvm.sh" ]] && source "${nvm_dir}/nvm.sh" 2>/dev/null || true
        if command -v node &>/dev/null; then
            current_node_major=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        fi
    fi

    if ((current_node_major >= MIN_NODE_MAJOR)); then
        print_status ok "Node.js v$(node -v 2>/dev/null | sed 's/^v//') (>= $MIN_NODE_MAJOR required)"
    else
        print_status info "Installing Node.js v24 via NVM..."
        if [[ "$CURRENT_USER" == "$target_user" ]]; then
            bash -c "$node_install_cmd" &>/dev/null &
            tui_spinner $! "Installing Node.js v24..." || true
        else
            run_with_sudo "su - $target_user -c '$node_install_cmd'" &>/dev/null &
            tui_spinner $! "Installing Node.js v24..." || true
        fi
        print_status ok "Node.js v24 installed"
    fi

    # --- OpenClaw ---
    # Reload NVM/PATH to find openclaw
    load_nvm_silent

    if command -v openclaw &>/dev/null; then
        print_status ok "OpenClaw already installed: $(openclaw --version 2>/dev/null)"
    else
        print_status info "Installing OpenClaw via official installer..."
        local oc_install="curl -fsSL https://openclaw.bot/install.sh | bash"
        if [[ "$CURRENT_USER" == "$target_user" ]]; then
            bash -c "$oc_install" &>/dev/null &
            tui_spinner $! "Installing OpenClaw..." || true
        else
            run_with_sudo "su - $target_user -c 'export NVM_DIR=\"${nvm_dir}\" && . \"\${NVM_DIR}/nvm.sh\" && $oc_install'" &>/dev/null &
            tui_spinner $! "Installing OpenClaw..." || true
        fi

        # Verify
        load_nvm_silent
        if command -v openclaw &>/dev/null; then
            print_status ok "OpenClaw installed: $(openclaw --version 2>/dev/null)"
        else
            print_status warn "OpenClaw installed but not in PATH. May need to log in as $target_user."
        fi
    fi

    state_save "phase_software_install" "done"
    printf "\n"
    print_status ok "Software installation complete"
}

# ---------- Phase 5: OpenClaw Setup ----------
phase_openclaw_setup() {
    printf "\n${BOLD}═══ Phase 5: OpenClaw Setup ═══${NC}\n\n"

    print_status info "OpenClaw onboard wizard will now run."
    printf "\n  It will ask you to configure:\n"
    printf "  ${DIM}• Model provider & authentication${NC}\n"
    printf "  ${DIM}  (Anthropic API key/setup-token, OpenRouter, OpenAI, Google, etc.)${NC}\n"
    printf "  ${DIM}• Workspace directory${NC}\n"
    printf "  ${DIM}• Gateway configuration (loopback/lan/tailnet)${NC}\n"
    printf "  ${DIM}• Messaging channels (Discord, Telegram, WhatsApp, Slack, Signal, iMessage)${NC}\n"
    printf "  ${DIM}• Systemd daemon installation${NC}\n"
    printf "\n"

    tui_menu "Ready to launch OpenClaw onboard?" \
        "Yes, launch onboard wizard" \
        "Skip (I'll run it manually later)"

    if ((TUI_RESULT == 0)); then
        printf "\n${CYAN}  Handing off to openclaw onboard...${NC}\n\n"

        local target_user="$OPENCLAW_USER"
        local target_home
        target_home=$(eval echo "~${target_user}")
        local nvm_dir="${target_home}/.nvm"
        local onboard_cmd="export NVM_DIR=\"${nvm_dir}\" && . \"\${NVM_DIR}/nvm.sh\" && openclaw onboard --install-daemon"

        if [[ "$CURRENT_USER" == "$target_user" ]]; then
            load_nvm_silent
            openclaw onboard --install-daemon
        else
            # Run interactively as openclaw user
            run_with_sudo "su - $target_user -c '$onboard_cmd'" < /dev/tty
        fi

        printf "\n"

        # Verify gateway
        load_nvm_silent
        if command -v openclaw &>/dev/null; then
            printf "\n  ${BOLD}Verifying gateway...${NC}\n"
            if openclaw gateway status &>/dev/null 2>&1; then
                print_status ok "OpenClaw gateway is running"
            else
                print_status warn "Gateway not detected. Check: openclaw gateway status"
            fi
        fi
    else
        print_status info "Skipped. Run manually as '$OPENCLAW_USER':"
        printf "    ${CYAN}openclaw onboard --install-daemon${NC}\n"
    fi

    # Print next steps
    printf "\n  ${BOLD}Next Steps${NC}\n"
    printf "  ${DIM}• Add channels later:${NC}   openclaw configure\n"
    printf "  ${DIM}• Health check:${NC}         openclaw doctor\n"
    printf "  ${DIM}• Gateway status:${NC}       openclaw gateway status\n"
    printf "  ${DIM}• Config file:${NC}          ~/.openclaw/openclaw.json\n"

    state_save "phase_openclaw_setup" "done"
    printf "\n"
    print_status ok "OpenClaw setup complete"
}

# ============================================================================
# SECTION F: Error Handling
# ============================================================================

on_error() {
    local line="$1"
    local cmd="$2"
    log "ERROR" "Line $line: $cmd"
    printf "\n"
    print_status fail "Error at line $line: $cmd"
    print_status info "Check log: $LOG_FILE"

    tui_menu "What would you like to do?" "Continue anyway" "Abort"
    if ((TUI_RESULT == 1)); then
        rollback_execute
        exit 1
    fi
}

rollback_push() {
    ROLLBACK_STACK+=("$1")
}

rollback_execute() {
    if ((${#ROLLBACK_STACK[@]} == 0)); then
        return
    fi
    printf "\n  ${BOLD}Rolling back changes...${NC}\n"
    local i
    for ((i = ${#ROLLBACK_STACK[@]} - 1; i >= 0; i--)); do
        print_status info "Undo: ${ROLLBACK_STACK[$i]}"
        eval "${ROLLBACK_STACK[$i]}" 2>/dev/null || true
    done
    ROLLBACK_STACK=()
    print_status ok "Rollback complete"
}

# Safe execution wrapper: run_safe "description" "command" ["rollback_command"]
run_safe() {
    local desc="$1"
    local cmd="$2"
    local rollback="${3:-}"

    [[ -n "$rollback" ]] && rollback_push "$rollback"

    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        print_status ok "$desc"
    else
        print_status fail "$desc"
        log "ERROR" "Failed: $cmd"
        return 1
    fi
}

log() {
    local level="$1"; shift
    local msg="$*"
    # Ensure log directory exists
    if [[ -d "$(dirname "$LOG_FILE")" ]]; then
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ============================================================================
# SECTION G: Main Entry Point
# ============================================================================

cleanup() {
    tput cnorm 2>/dev/null || true
    printf "${NC}"
}

run_full_setup() {
    phase_system_check || return 1
    printf "\n"
    tui_menu "Continue to User Setup?" "Yes" "Stop here"
    ((TUI_RESULT == 1)) && return 0

    phase_user_setup || return 1
    printf "\n"
    tui_menu "Continue to Security Setup?" "Yes" "Stop here"
    ((TUI_RESULT == 1)) && return 0

    phase_security_setup
    printf "\n"
    tui_menu "Continue to Software Installation?" "Yes" "Stop here"
    ((TUI_RESULT == 1)) && return 0

    phase_software_install || return 1
    printf "\n"
    tui_menu "Continue to OpenClaw Setup?" "Yes" "Stop here"
    ((TUI_RESULT == 1)) && return 0

    phase_openclaw_setup
    printf "\n"
    print_status ok "Full setup complete!"
}

main() {
    ensure_not_piped "$@"
    trap cleanup EXIT
    trap 'on_error $LINENO "$BASH_COMMAND"' ERR

    print_banner

    # Initialize state persistence (needs sudo for /opt/openclaw)
    detect_user
    state_init
    state_load

    # Check if resuming
    local has_state=false
    [[ -s "$STATE_FILE" ]] && has_state=true

    while true; do
        if $has_state; then
            state_show_summary
        fi

        local menu_label="Run Full Setup (Recommended)"
        $has_state && menu_label="Resume Full Setup"

        tui_menu "Main Menu" \
            "$menu_label" \
            "Phase 1: System Check" \
            "Phase 2: User Setup" \
            "Phase 3: Security Setup" \
            "Phase 4: Software Install" \
            "Phase 5: OpenClaw Setup" \
            "View Status" \
            "Exit"

        case "$TUI_RESULT" in
            0) run_full_setup ;;
            1) phase_system_check ;;
            2) phase_user_setup ;;
            3) phase_security_setup ;;
            4) phase_software_install ;;
            5) phase_openclaw_setup ;;
            6) state_show_summary ;;
            7) printf "\n"; print_status info "Goodbye!"; exit 0 ;;
        esac

        printf "\n"
        tui_menu "Return to main menu?" "Yes" "Exit"
        ((TUI_RESULT == 1)) && { printf "\n"; print_status info "Goodbye!"; exit 0; }
    done
}

main "$@"
