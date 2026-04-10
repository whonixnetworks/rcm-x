#!/usr/bin/env bash
# ============================================================
#  RCM-X v2.2 — rclone + mergerfs union mount setup
#  author: greedy
#  Combines a local directory with an rclone remote via
#  mergerfs into a single unified working directory.
#  All new writes go local; remote is visible via the union.
# ============================================================

# ── Colour palette ───────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

log()     { echo -e "${BLUE}==>${NC} ${WHITE}$*${NC}"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC}  $*"; }
error()   { echo -e "${RED}  ✗${NC} $*" >&2; }
section() { echo -e "\n${MAGENTA}━━━ $* ━━━${NC}"; }
dim()     { echo -e "${GRAY}    $*${NC}"; }
die()     { error "$*"; exit 1; }

# ── Globals ──────────────────────────────────────────────────
WHOAMI="$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")"
USER_HOME="/home/${WHOAMI}"
RCLONE_CONF="${USER_HOME}/.config/rclone/rclone.conf"
FUSE_CONF="/etc/fuse.conf"
SYSTEMD_DIR="/etc/systemd/system"
LOG_DIR="/var/log/rcmx"
RCMX_INSTALL_PATH="/usr/local/bin/rcmx"

MERGED_DIR=""
LOCAL_DIR=""
REMOTE_MOUNT_DIR=""
REMOTE=""
REMOTE_PATH=""
INSTANCE_NAME=""
VFS_CACHE_SIZE="10G"
TRANSFERS="4"
MERGED_ONLY="false"   # string bool — never use bare $VAR as command
RCMX_HIDDEN_BASE=""

RCLONE_SERVICE_FILE=""
MERGERFS_SERVICE_FILE=""
RCLONE_LOG_FILE=""
USER_UID=""
USER_GID=""

# ── Header ───────────────────────────────────────────────────
print_header() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${WHITE}RCM-X v2.2${NC} — rclone + mergerfs setup  ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}\n"
}

# ── Sudo helper — only escalates when not already root ───────
sudo_run() {
    local desc="$1"; shift
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        echo -e "${YELLOW}  ⚠${NC}  Elevated access required for: ${WHITE}${desc}${NC}"
        sudo "$@"
    fi
}

sudo_write_file() {
    local path="$1"
    local content="$2"
    if [[ $EUID -eq 0 ]]; then
        printf '%s\n' "$content" > "$path"
    else
        echo -e "${YELLOW}  ⚠${NC}  Elevated access required to write: ${WHITE}${path}${NC}"
        printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    fi
}

# ── Dependency installer ──────────────────────────────────────
install_dep_apt() {
    local name="$1"
    local pkg="$2"
    warn "$name is not installed."
    read -rp "  Install $name now? [Y/n]: " ans
    ans="${ans:-Y}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        die "$name is required. Aborting."
    fi
    log "Installing $name..."
    if sudo_run "apt install $pkg" apt-get install -y "$pkg"; then
        success "$name installed."
    else
        die "Failed to install $name."
    fi
}

# ── Preflight checks ─────────────────────────────────────────
apt_checks() {
    section "Preflight Checks"

    # mergerfs
    if dpkg -l mergerfs 2>/dev/null | grep -q "^ii"; then
        success "mergerfs installed"
    else
        install_dep_apt "mergerfs" "mergerfs"
    fi

    # rclone
    if command -v rclone &>/dev/null; then
        success "rclone installed ($(rclone --version 2>/dev/null | head -1))"
    else
        warn "rclone is not installed."
        read -rp "  Install rclone now via official script? [Y/n]: " ans
        ans="${ans:-Y}"
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            log "Installing rclone..."
            if curl -fsSL https://rclone.org/install.sh | sudo bash; then
                success "rclone installed."
            else
                die "rclone install failed. Visit https://rclone.org/install/"
            fi
        else
            die "rclone is required. Aborting."
        fi
    fi

    # rclone config
    if [[ -f "$RCLONE_CONF" ]]; then
        success "rclone config found: $RCLONE_CONF"
    else
        error "rclone config not found: $RCLONE_CONF"
        dim "Run 'rclone config' as ${WHOAMI} to set up a remote, then re-run RCM-X."
        exit 1
    fi

    # fusermount
    if command -v fusermount3 &>/dev/null || command -v fusermount &>/dev/null; then
        success "fusermount available"
    else
        install_dep_apt "fuse" "fuse3"
    fi

    # fuse.conf — user_allow_other needed for Docker to see mergerfs mounts
    if grep -q "^user_allow_other" "$FUSE_CONF" 2>/dev/null; then
        success "user_allow_other already enabled in $FUSE_CONF"
    elif grep -q "^#user_allow_other" "$FUSE_CONF" 2>/dev/null; then
        warn "Enabling user_allow_other in $FUSE_CONF..."
        sudo_run "edit fuse.conf" sed -i 's/^#user_allow_other/user_allow_other/' "$FUSE_CONF"
        success "user_allow_other enabled"
    else
        warn "Adding user_allow_other to $FUSE_CONF..."
        echo "user_allow_other" | sudo_run "append fuse.conf" tee -a "$FUSE_CONF" >/dev/null
        success "user_allow_other added"
    fi

    success "All preflight checks passed."
}

# ── Read a directory path with a prefilled default ───────────
# Usage: read_dir "prompt text" "default_path" VAR_NAME
read_dir() {
    local prompt="$1"
    local default="$2"
    local varname="$3"
    local input
    read -rp "  → ${prompt} [${default}]: " input
    input="${input:-$default}"
    # Expand ~ if user typed it
    input="${input/#\~/$HOME}"
    printf -v "$varname" '%s' "$input"
}

# ── Interactive config ───────────────────────────────────────
rcmx_config() {
    section "RCM-X Configuration"

    # ── Instance name ────────────────────────────────────────
    echo -e "${CYAN}Instance Name${NC}"
    dim "A short label to identify this mount setup (e.g. 'media', 'backup', 'tv')."
    dim "Used to name the systemd services. Run setup again with a different"
    dim "name to create multiple independent mounts on the same machine."
    read -rp "  → Name: " INSTANCE_NAME
    [[ -z "$INSTANCE_NAME" ]] && die "Instance name cannot be empty."
    INSTANCE_NAME=$(echo "$INSTANCE_NAME" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs '[:alnum:]-' '-' \
        | sed 's/-*$//')

    RCLONE_SERVICE_FILE="rcmx-rclone-${INSTANCE_NAME}.service"
    MERGERFS_SERVICE_FILE="rcmx-mergerfs-${INSTANCE_NAME}.service"
    RCLONE_LOG_FILE="${LOG_DIR}/rclone-${INSTANCE_NAME}.log"

    echo ""

    # ── Mode selection ────────────────────────────────────────
    echo -e "${CYAN}Mode Selection${NC}"
    echo ""
    echo -e "  ${WHITE}[1] Standard mode${NC} ${GRAY}(default)${NC}"
    dim "      You choose all three directories: working view, local storage,"
    dim "      and where rclone attaches the remote. Full control."
    echo ""
    echo -e "  ${WHITE}[2] Merged-only mode${NC}"
    dim "      You only specify one working directory. RCM-X hides the local"
    dim "      storage and remote mount in a private subfolder inside it."
    dim "      Cleaner — you only ever see the merged view."
    echo ""
    read -rp "  → Select mode [1/2] (default: 1): " mode_choice
    mode_choice="${mode_choice:-1}"

    if [[ "$mode_choice" == "2" ]]; then
        MERGED_ONLY="true"
        success "Merged-only mode selected"
    else
        MERGED_ONLY="false"
        success "Standard mode selected"
    fi

    echo ""

    # ── Directory prompts ─────────────────────────────────────
    if [[ "$MERGED_ONLY" == "true" ]]; then

        echo -e "${CYAN}Working Directory${NC}"
        dim "The single directory you'll work from. Shows your local files and"
        dim "cloud files together as if they were all in one place."
        dim "Apps, Docker containers, and Jellyfin should point here."
        read_dir "Full path" "${USER_HOME}/merged" MERGED_DIR

        RCMX_HIDDEN_BASE="${MERGED_DIR}/.rcmx-${INSTANCE_NAME}"
        LOCAL_DIR="${RCMX_HIDDEN_BASE}/local"
        REMOTE_MOUNT_DIR="${RCMX_HIDDEN_BASE}/remote"

        echo ""
        dim "Local storage hidden at : $LOCAL_DIR"
        dim "Remote mount hidden at  : $REMOTE_MOUNT_DIR"
        dim "Both visible only via   : $MERGED_DIR"

    else

        echo -e "${CYAN}Working Directory${NC} ${GRAY}(the merged view — where you actually work)${NC}"
        dim "Shows your local files and cloud files together in one place."
        dim "Point your apps, Docker volumes, and media servers here."
        read_dir "Full path" "${USER_HOME}/merged" MERGED_DIR

        echo ""

        echo -e "${CYAN}Local Storage Directory${NC} ${GRAY}(fast local disk — where new files are physically written)${NC}"
        dim "When anything writes into the working directory, it lands here first."
        dim "Files stay here until you push them to the cloud with rcmv."
        read_dir "Full path" "${USER_HOME}/local" LOCAL_DIR

        echo ""

        echo -e "${CYAN}Remote Mount Directory${NC} ${GRAY}(private — where rclone attaches your cloud storage)${NC}"
        dim "RCM-X mounts your cloud remote here so mergerfs can read it."
        dim "You don't work here directly. It must be an empty directory."
        read_dir "Full path" "${USER_HOME}/remote" REMOTE_MOUNT_DIR

    fi

    echo ""

    # ── rclone remote ─────────────────────────────────────────
    echo -e "${CYAN}Cloud Remote${NC} ${GRAY}(which rclone remote holds your cloud files)${NC}"
    dim "For encrypted remotes (GCrypt, crypt), pick the encrypted one —"
    dim "not the underlying Google Drive or S3 remote behind it."
    echo ""

    local remotes
    remotes=$(rclone listremotes --config="$RCLONE_CONF" 2>/dev/null) || {
        die "Failed to list rclone remotes. Check your rclone config."
    }
    [[ -z "$remotes" ]] && die "No rclone remotes found. Run 'rclone config' first."

    local i=1
    local remote_array=()
    while IFS= read -r r; do
        echo -e "    ${WHITE}[$i]${NC} ${r}"
        remote_array+=("$r")
        (( i++ )) || true
    done <<< "$remotes"

    echo ""
    read -rp "  → Select [1-$((i-1))] or type name: " remote_choice

    if [[ "$remote_choice" =~ ^[0-9]+$ ]]; then
        local idx=$(( remote_choice - 1 ))
        if [[ $idx -lt 0 || $idx -ge ${#remote_array[@]} ]]; then
            die "Invalid selection: $remote_choice"
        fi
        REMOTE="${remote_array[$idx]}"
    else
        if echo "$remotes" | grep -qF "${remote_choice}:"; then
            REMOTE="${remote_choice}:"
        elif echo "$remotes" | grep -qF "${remote_choice}"; then
            REMOTE="$remote_choice"
        else
            die "Remote not found: $remote_choice"
        fi
    fi
    [[ "$REMOTE" != *: ]] && REMOTE="${REMOTE}:"
    success "Selected: $REMOTE"

    echo ""

    # ── Remote subfolder ──────────────────────────────────────
    echo -e "${CYAN}Remote Subfolder${NC} ${GRAY}(optional — which folder inside the remote to mount)${NC}"
    dim "Leave blank to mount the root of the remote."
    dim "Example: 'media' mounts ${REMOTE}media  |  blank mounts ${REMOTE} (root)"
    read -rp "  → Subfolder [leave blank for root]: " REMOTE_PATH
    REMOTE_PATH="${REMOTE_PATH%/}"

    echo ""

    # ── Performance ───────────────────────────────────────────
    echo -e "${CYAN}VFS Cache Size${NC} ${GRAY}(local disk rclone uses to cache remote file reads)${NC}"
    dim "Larger = smoother playback from remote. 10G is fine for most setups."
    read -rp "  → Size [10G]: " VFS_CACHE_SIZE
    VFS_CACHE_SIZE="${VFS_CACHE_SIZE:-10G}"

    echo ""
    echo -e "${CYAN}Parallel Transfers${NC} ${GRAY}(concurrent upload/download threads)${NC}"
    dim "Higher = faster for many small files. 4 is good for single-user setups."
    read -rp "  → Count [4]: " TRANSFERS
    TRANSFERS="${TRANSFERS:-4}"

    echo ""

    # ── Confirm ───────────────────────────────────────────────
    local mode_label="Standard"
    [[ "$MERGED_ONLY" == "true" ]] && mode_label="Merged-only"

    section "Confirm Configuration"
    echo -e "  ${WHITE}Instance        :${NC} ${CYAN}${INSTANCE_NAME}${NC}"
    echo -e "  ${WHITE}Mode            :${NC} ${CYAN}${mode_label}${NC}"
    echo -e "  ${WHITE}Working dir     :${NC} ${CYAN}${MERGED_DIR}${NC}"
    echo -e "  ${WHITE}Local storage   :${NC} ${CYAN}${LOCAL_DIR}${NC}"
    echo -e "  ${WHITE}Remote mount    :${NC} ${CYAN}${REMOTE_MOUNT_DIR}${NC}"
    echo -e "  ${WHITE}Cloud remote    :${NC} ${CYAN}${REMOTE}${REMOTE_PATH}${NC}"
    echo -e "  ${WHITE}VFS cache       :${NC} ${CYAN}${VFS_CACHE_SIZE}${NC}"
    echo -e "  ${WHITE}Transfers       :${NC} ${CYAN}${TRANSFERS}${NC}"
    echo -e "  ${WHITE}rclone service  :${NC} ${CYAN}${RCLONE_SERVICE_FILE}${NC}"
    echo -e "  ${WHITE}mergerfs service:${NC} ${CYAN}${MERGERFS_SERVICE_FILE}${NC}"
    echo -e "  ${WHITE}Log file        :${NC} ${CYAN}${RCLONE_LOG_FILE}${NC}"
    echo ""

    read -rp "Continue with setup? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
}

# ── Get real user UID/GID ────────────────────────────────────
get_user_ids() {
    USER_UID=$(id -u "$WHOAMI")
    USER_GID=$(id -g "$WHOAMI")
}

# ── Create directories ───────────────────────────────────────
create_dirs() {
    section "Creating Directories"

    local dirs=("$MERGED_DIR" "$LOCAL_DIR" "$REMOTE_MOUNT_DIR" "$LOG_DIR")

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            success "Already exists: $dir"
        else
            sudo_run "create $dir" mkdir -p "$dir"
            success "Created: $dir"
        fi
        sudo_run "chown $dir" chown "${WHOAMI}:${WHOAMI}" "$dir"
    done

    # In merged-only mode, secure the hidden backing dir but keep it accessible
    # 755 allows the user to access it while preventing others from listing
    if [[ "$MERGED_ONLY" == "true" ]] && [[ -n "$RCMX_HIDDEN_BASE" ]]; then
        sudo_run "secure hidden dir" chmod 755 "$RCMX_HIDDEN_BASE"
        success "Hidden backing dir secured (755): $RCMX_HIDDEN_BASE"
    fi

    sudo_run "create log" touch "$RCLONE_LOG_FILE"
    sudo_run "chown log" chown "${WHOAMI}:${WHOAMI}" "$RCLONE_LOG_FILE"
    success "Log file ready: $RCLONE_LOG_FILE"
}

# ── Write rclone service ─────────────────────────────────────
write_rclone_service() {
    section "Writing rclone Systemd Service"

    local remote_full="${REMOTE}${REMOTE_PATH}"
    local service_path="${SYSTEMD_DIR}/${RCLONE_SERVICE_FILE}"

    # Use a single continuous line for ExecStart - systemd does NOT handle
    # backslash continuations properly in service files
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<SVCEOF
[Unit]
Description=RCM-X rclone mount — ${INSTANCE_NAME}
After=network-online.target
Wants=network-online.target
AssertPathIsDirectory=${REMOTE_MOUNT_DIR}

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount ${remote_full} ${REMOTE_MOUNT_DIR} --config=${RCLONE_CONF} --vfs-cache-mode=full --vfs-cache-max-size=${VFS_CACHE_SIZE} --vfs-cache-max-age=24h --vfs-read-chunk-size=128M --vfs-read-chunk-size-limit=off --dir-cache-time=72h --poll-interval=15s --transfers=${TRANSFERS} --allow-other --umask=002 --uid=${USER_UID} --gid=${USER_GID} --log-level=NOTICE --log-file=${RCLONE_LOG_FILE}
ExecStop=/bin/fusermount -uz ${REMOTE_MOUNT_DIR}
Restart=on-failure
RestartSec=10
User=${WHOAMI}
Group=${WHOAMI}

[Install]
WantedBy=multi-user.target
SVCEOF

    sudo_run "install rclone service" cp "$tmpfile" "$service_path"
    sudo_run "chmod rclone service" chmod 644 "$service_path"
    rm -f "$tmpfile"
    success "Written: $service_path"
}

# ── Write mergerfs service ───────────────────────────────────
write_mergerfs_service() {
    section "Writing mergerfs Systemd Service"

    local service_path="${SYSTEMD_DIR}/${MERGERFS_SERVICE_FILE}"

    local fusermount_bin="fusermount"
    command -v fusermount3 &>/dev/null && fusermount_bin="fusermount3"

    local tmpfile
    tmpfile=$(mktemp)

    # Build mergerfs options - add 'nonempty' for merged-only mode since the
    # merged directory contains the hidden .rcmx-* directory from rclone mount
    local mergerfs_opts="defaults,allow_other,use_ino"
    if [[ "$MERGED_ONLY" == "true" ]]; then
        mergerfs_opts="${mergerfs_opts},nonempty"
    fi

    cat > "$tmpfile" <<SVCEOF
[Unit]
Description=RCM-X mergerfs union mount — ${INSTANCE_NAME}
After=${RCLONE_SERVICE_FILE}
Requires=${RCLONE_SERVICE_FILE}
AssertPathIsDirectory=${MERGED_DIR}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mergerfs ${LOCAL_DIR}:${REMOTE_MOUNT_DIR} ${MERGED_DIR} -o ${mergerfs_opts} -o category.create=ff -o fsname=rcmx-${INSTANCE_NAME} -o minfreespace=10G -o umask=002
ExecStop=/bin/${fusermount_bin} -uz ${MERGED_DIR}
RemoveIPC=true

[Install]
WantedBy=multi-user.target
SVCEOF

    sudo_run "install mergerfs service" cp "$tmpfile" "$service_path"
    sudo_run "chmod mergerfs service" chmod 644 "$service_path"
    rm -f "$tmpfile"
    success "Written: $service_path"
}

# ── Enable services ──────────────────────────────────────────
enable_services() {
    section "Enabling Systemd Services"

    sudo_run "daemon-reload" systemctl daemon-reload
    success "systemd daemon reloaded"

    log "Enabling and starting ${RCLONE_SERVICE_FILE}..."
    
    # Enable the service first
    sudo_run "enable rclone" systemctl enable "$RCLONE_SERVICE_FILE" 2>/dev/null
    
    # Start and verify rclone service
    if sudo_run "start rclone" systemctl start "$RCLONE_SERVICE_FILE"; then
        sleep 3
        if systemctl is-active --quiet "$RCLONE_SERVICE_FILE"; then
            success "rclone service active"
        else
            echo ""
            error "rclone service failed to start."
            echo ""
            dim "Service status:"
            sudo systemctl status "$RCLONE_SERVICE_FILE" --no-pager -l 2>/dev/null || true
            echo ""
            dim "Check logs with: sudo journalctl -xeu $RCLONE_SERVICE_FILE"
            dim "Common causes:"
            dim "  - Remote name incorrect or not configured"
            dim "  - Remote mount directory not accessible (check permissions)"
            dim "  - rclone config missing or invalid"
            dim "  - Network connectivity issues"
            exit 1
        fi
    else
        error "Failed to start rclone service"
        exit 1
    fi

    # Verify rclone mount is actually mounted
    sleep 2
    if ! mountpoint -q "$REMOTE_MOUNT_DIR"; then
        error "rclone mount not active after start: $REMOTE_MOUNT_DIR"
        dim "Check rclone logs: sudo journalctl -xeu $RCLONE_SERVICE_FILE"
        dim "Also check: cat $RCLONE_LOG_FILE"
        exit 1
    fi
    success "rclone mount verified at: $REMOTE_MOUNT_DIR"

    log "Enabling and starting ${MERGERFS_SERVICE_FILE}..."
    
    # Enable the service
    sudo_run "enable mergerfs" systemctl enable "$MERGERFS_SERVICE_FILE" 2>/dev/null
    
    # Start and verify mergerfs service
    if sudo_run "start mergerfs" systemctl start "$MERGERFS_SERVICE_FILE"; then
        sleep 2
        if systemctl is-active --quiet "$MERGERFS_SERVICE_FILE"; then
            success "mergerfs service active"
        else
            echo ""
            error "mergerfs service failed to start."
            echo ""
            dim "Service status:"
            sudo systemctl status "$MERGERFS_SERVICE_FILE" --no-pager -l 2>/dev/null || true
            echo ""
            dim "Check logs with: sudo journalctl -xeu $MERGERFS_SERVICE_FILE"
            exit 1
        fi
    else
        error "Failed to start mergerfs service"
        exit 1
    fi
}
# ── Verify mounts ────────────────────────────────────────────
verify_mounts() {
    section "Verifying Mounts"
    local ok="true"

    if mountpoint -q "$REMOTE_MOUNT_DIR"; then
        success "rclone mount active: $REMOTE_MOUNT_DIR"
    else
        error "rclone mount NOT active: $REMOTE_MOUNT_DIR"
        ok="false"
    fi

    if mountpoint -q "$MERGED_DIR"; then
        success "mergerfs mount active: $MERGED_DIR"
    else
        error "mergerfs mount NOT active: $MERGED_DIR"
        ok="false"
    fi

    if [[ "$ok" == "true" ]]; then
        echo ""
        success "All mounts verified."
        echo ""
        echo -e "  ${WHITE}Working directory :${NC} ${CYAN}${MERGED_DIR}${NC}"
        if [[ "$MERGED_ONLY" != "true" ]]; then
            echo -e "  ${WHITE}Local storage     :${NC} ${CYAN}${LOCAL_DIR}${NC}"
            echo -e "  ${WHITE}Remote mount      :${NC} ${CYAN}${REMOTE_MOUNT_DIR}${NC}"
        fi
        echo ""
        dim "New writes to the working directory land in local storage."
        dim "Use rcmv to push local files to the remote when ready."
    else
        echo ""
        warn "One or more mounts failed. Diagnose with:"
        dim "sudo journalctl -xeu $RCLONE_SERVICE_FILE"
        dim "sudo journalctl -xeu $MERGERFS_SERVICE_FILE"
        exit 1
    fi
}

# ── Install rcmx system command + shell aliases ──────────────
install_rcmx_command() {
    section "Installing rcmx Command"

    local script_source
    script_source="$(realpath "$0")"

    sudo_run "install to $RCMX_INSTALL_PATH" cp "$script_source" "$RCMX_INSTALL_PATH"
    sudo_run "chmod rcmx" chmod +x "$RCMX_INSTALL_PATH"
    success "Installed: $RCMX_INSTALL_PATH"

    # Detect login shell from passwd db
    local shell_name rc_file
    shell_name=$(getent passwd "$WHOAMI" 2>/dev/null | cut -d: -f7 | xargs basename 2>/dev/null \
        || basename "${SHELL:-bash}")

    case "$shell_name" in
        zsh)  rc_file="${USER_HOME}/.zshrc" ;;
        bash) rc_file="${USER_HOME}/.bashrc" ;;
        fish) rc_file="${USER_HOME}/.config/fish/config.fish" ;;
        *)    rc_file="${USER_HOME}/.bashrc" ;;
    esac

    success "Detected shell: $shell_name → $rc_file"

    if grep -q "# rcmx — RCM-X aliases" "$rc_file" 2>/dev/null; then
        success "rcmx aliases already in $rc_file"
    else
        log "Adding rcmx aliases to $rc_file..."
        cat >> "$rc_file" <<'ALIASES'

# rcmx — RCM-X aliases (added by rcmx setup)
alias rcmx='sudo /usr/local/bin/rcmx'
alias rcmx-status='sudo /usr/local/bin/rcmx status'
alias rcmx-start='sudo /usr/local/bin/rcmx start'
alias rcmx-stop='sudo /usr/local/bin/rcmx stop'
alias rcmx-restart='sudo /usr/local/bin/rcmx restart'
alias rcmx-logs='sudo /usr/local/bin/rcmx logs'
alias rcmx-uninstall='sudo /usr/local/bin/rcmx uninstall'
ALIASES
        success "Aliases added to $rc_file"
        warn "Run: source $rc_file  (or open a new terminal) to use rcmx"
    fi
}

# ── Instance selector ────────────────────────────────────────
require_instance() {
    local instances=()
    for f in "${SYSTEMD_DIR}"/rcmx-rclone-*.service; do
        [[ -f "$f" ]] || continue
        instances+=("$(basename "$f" | sed 's/rcmx-rclone-//;s/\.service//')")
    done

    if [[ ${#instances[@]} -eq 0 ]]; then
        die "No RCM-X instances found. Run setup first."
    elif [[ ${#instances[@]} -eq 1 ]]; then
        INSTANCE_NAME="${instances[0]}"
        dim "Instance: $INSTANCE_NAME"
    else
        echo -e "\n${CYAN}Multiple instances:${NC}"
        local i=1
        for inst in "${instances[@]}"; do
            echo -e "  ${WHITE}[$i]${NC} $inst"
            (( i++ )) || true
        done
        read -rp "  → Select instance: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            INSTANCE_NAME="${instances[$((choice-1))]}"
        else
            INSTANCE_NAME="$choice"
        fi
    fi

    RCLONE_SERVICE_FILE="rcmx-rclone-${INSTANCE_NAME}.service"
    MERGERFS_SERVICE_FILE="rcmx-mergerfs-${INSTANCE_NAME}.service"
    RCLONE_LOG_FILE="${LOG_DIR}/rclone-${INSTANCE_NAME}.log"
}

# ── Service control ───────────────────────────────────────────
do_start() {
    require_instance
    section "Starting — ${INSTANCE_NAME}"
    if sudo_run "start rclone" systemctl start "$RCLONE_SERVICE_FILE"; then
        success "rclone started"
    else
        error "rclone failed to start"
    fi
    sleep 2
    if sudo_run "start mergerfs" systemctl start "$MERGERFS_SERVICE_FILE"; then
        success "mergerfs started"
    else
        error "mergerfs failed to start"
    fi
}

do_stop() {
    require_instance
    section "Stopping — ${INSTANCE_NAME}"
    if sudo_run "stop mergerfs" systemctl stop "$MERGERFS_SERVICE_FILE" 2>/dev/null; then
        success "mergerfs stopped"
    else
        warn "mergerfs was not running"
    fi
    if sudo_run "stop rclone" systemctl stop "$RCLONE_SERVICE_FILE" 2>/dev/null; then
        success "rclone stopped"
    else
        warn "rclone was not running"
    fi
}

do_restart() {
    do_stop
    sleep 2
    do_start
}

do_logs() {
    require_instance
    section "Logs — ${INSTANCE_NAME}"
    echo -e "${GRAY}─── systemd: rclone ──────────────────────────────${NC}"
    sudo journalctl -u "$RCLONE_SERVICE_FILE" -n 30 --no-pager 2>/dev/null || true
    echo -e "\n${GRAY}─── systemd: mergerfs ────────────────────────────${NC}"
    sudo journalctl -u "$MERGERFS_SERVICE_FILE" -n 20 --no-pager 2>/dev/null || true
    if [[ -f "$RCLONE_LOG_FILE" ]]; then
        echo -e "\n${GRAY}─── rclone log (last 20 lines) ───────────────────${NC}"
        tail -n 20 "$RCLONE_LOG_FILE"
    fi
}

# ── Status ───────────────────────────────────────────────────
show_status() {
    section "RCM-X Instance Status"

    local found="false"
    for f in "${SYSTEMD_DIR}"/rcmx-rclone-*.service; do
        [[ -f "$f" ]] || continue
        found="true"
        local name
        name=$(basename "$f" | sed 's/rcmx-rclone-//;s/\.service//')

        local rclone_svc="rcmx-rclone-${name}.service"
        local mergerfs_svc="rcmx-mergerfs-${name}.service"

        echo -e "\n  ${WHITE}Instance:${NC} ${CYAN}${name}${NC}"

        if systemctl is-active --quiet "$rclone_svc" 2>/dev/null; then
            echo -e "    rclone  : ${GREEN}● active${NC}"
        else
            echo -e "    rclone  : ${RED}○ inactive${NC}"
        fi

        if systemctl is-active --quiet "$mergerfs_svc" 2>/dev/null; then
            echo -e "    mergerfs: ${GREEN}● active${NC}"
        else
            echo -e "    mergerfs: ${RED}○ inactive${NC}"
        fi

        local mount_point
        mount_point=$(grep -oP '(?<=-uz )\S+' "${SYSTEMD_DIR}/${mergerfs_svc}" 2>/dev/null \
            | head -1 || echo "unknown")
        echo -e "    mount   : ${GRAY}${mount_point}${NC}"

        local log_file="${LOG_DIR}/rclone-${name}.log"
        if [[ -f "$log_file" ]]; then
            local log_size
            log_size=$(du -sh "$log_file" 2>/dev/null | cut -f1)
            echo -e "    log     : ${GRAY}${log_file} (${log_size})${NC}"
        fi
    done

    if [[ "$found" == "false" ]]; then
        echo -e "\n  ${GRAY}No RCM-X instances found. Run setup to create one.${NC}"
    fi
    echo ""
}

# ── Uninstall ────────────────────────────────────────────────
do_uninstall() {
    section "RCM-X Uninstall"
    require_instance

    echo ""
    warn "This removes systemd services for instance: ${INSTANCE_NAME}"
    warn "Your directories and files will NOT be deleted."
    read -rp "  Continue? [y/N]: " ans
    ans="${ans:-N}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    for svc in "$MERGERFS_SERVICE_FILE" "$RCLONE_SERVICE_FILE"; do
        if sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
            sudo_run "stop $svc" systemctl stop "$svc"
            success "Stopped: $svc"
        fi
        if sudo systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            sudo_run "disable $svc" systemctl disable "$svc"
            success "Disabled: $svc"
        fi
        if [[ -f "${SYSTEMD_DIR}/${svc}" ]]; then
            sudo_run "remove $svc" rm -f "${SYSTEMD_DIR}/${svc}"
            success "Removed: ${SYSTEMD_DIR}/${svc}"
        fi
    done

    sudo_run "daemon-reload" systemctl daemon-reload
    echo ""
    success "Instance '${INSTANCE_NAME}' removed."
    dim "Log file left intact: ${LOG_DIR}/rclone-${INSTANCE_NAME}.log"
}

# ── Usage ────────────────────────────────────────────────────
usage() {
    echo -e "\n${WHITE}Usage:${NC} rcmx [command]"
    echo ""
    echo -e "  ${CYAN}(no args)${NC}                     Run interactive setup"
    echo ""
    echo -e "  ${WHITE}Instance Control:${NC}"
    echo -e "  ${CYAN}start${NC}    | ${CYAN}-s${NC} | ${CYAN}--start${NC}     Start rclone + mergerfs"
    echo -e "  ${CYAN}stop${NC}     | ${CYAN}-x${NC} | ${CYAN}--stop${NC}      Stop mergerfs + rclone"
    echo -e "  ${CYAN}restart${NC}  | ${CYAN}-r${NC} | ${CYAN}--restart${NC}   Restart both services"
    echo ""
    echo -e "  ${WHITE}Info:${NC}"
    echo -e "  ${CYAN}status${NC}   | ${CYAN}-S${NC} | ${CYAN}--status${NC}    Show all instance status"
    echo -e "  ${CYAN}logs${NC}     | ${CYAN}-l${NC} | ${CYAN}--logs${NC}      Show logs for an instance"
    echo ""
    echo -e "  ${WHITE}Management:${NC}"
    echo -e "  ${CYAN}uninstall${NC}| ${CYAN}-u${NC} | ${CYAN}--uninstall${NC} Remove an instance"
    echo -e "  ${CYAN}help${NC}     | ${CYAN}-h${NC} | ${CYAN}--help${NC}      Show this message"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    print_header

    local cmd="${1:-}"

    case "$cmd" in
        status|-S|--status)       show_status ;;
        logs|-l|--logs)           do_logs ;;
        help|-h|--help)           usage ;;
        start|-s|--start)         do_start ;;
        stop|-x|--stop)           do_stop ;;
        restart|-r|--restart)     do_restart ;;
        uninstall|-u|--uninstall) do_uninstall ;;

        "")
            apt_checks
            rcmx_config
            get_user_ids
            create_dirs
            write_rclone_service
            write_mergerfs_service
            enable_services
            verify_mounts
            install_rcmx_command
            section "Setup Complete"
            success "RCM-X instance '${INSTANCE_NAME}' is live."
            dim "Use 'rcmx status' to check at any time."
            dim "Use 'rcmx stop' / 'rcmx start' to control the mount."
            echo ""
            ;;

        *)
            error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
