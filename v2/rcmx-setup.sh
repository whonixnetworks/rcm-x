#!/usr/bin/env bash
# ============================================================
#  RCM-X v2.0 — rclone + mergerfs union mount setup
#  author: greedy
#  Combines a local directory with an rclone remote via
#  mergerfs into a single unified working directory.
#  All new writes go local; remote is read-only via the union.
# ============================================================

set -euo pipefail

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
error()   { echo -e "${RED}  ✗${NC} $*"; }
section() { echo -e "\n${MAGENTA}━━━ $* ━━━${NC}"; }
dim()     { echo -e "${GRAY}    $*${NC}"; }
die()     { error "$*"; exit 1; }

# ── Globals (populated by rcmx_config) ──────────────────────
WHOAMI="${SUDO_USER:-$(whoami)}"
USER_HOME="/home/${WHOAMI}"
RCLONE_CONF="${USER_HOME}/.config/rclone/rclone.conf"
FUSE_CONF="/etc/fuse.conf"
SYSTEMD_DIR="/etc/systemd/system"
LOG_DIR="/var/log/rcmx"

MERGED_DIR=""
LOCAL_DIR=""
REMOTE_MOUNT_DIR=""
REMOTE=""
REMOTE_PATH=""
INSTANCE_NAME=""

RCLONE_SERVICE_FILE=""
MERGERFS_SERVICE_FILE=""
RCLONE_LOG_FILE=""

# ── Header ───────────────────────────────────────────────────
print_header() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${WHITE}RCM-X v2.0${NC} — rclone + mergerfs setup  ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}\n"
}

# ── Preflight checks ─────────────────────────────────────────
apt_checks() {
    section "Preflight Checks"

    # Must run as root (for systemd installs, fuse.conf edits)
    if [[ $EUID -ne 0 ]]; then
        die "RCM-X must be run with sudo. Example: sudo ./rcmx-setup.sh"
    fi

    # mergerfs
    if dpkg -l mergerfs 2>/dev/null | grep -q "^ii"; then
        success "mergerfs installed"
    else
        error "mergerfs is NOT installed."
        echo -e "    Install with: ${CYAN}sudo apt install mergerfs${NC}"
        exit 1
    fi

    # rclone
    if command -v rclone &>/dev/null; then
        success "rclone installed ($(rclone --version 2>/dev/null | head -1))"
    else
        error "rclone is NOT installed."
        echo -e "    Install with: ${CYAN}sudo apt install rclone${NC} or https://rclone.org/install/"
        exit 1
    fi

    # rclone config
    if [[ -f "$RCLONE_CONF" ]]; then
        success "rclone config found: $RCLONE_CONF"
    else
        error "rclone config not found: $RCLONE_CONF"
        echo -e "    Run ${CYAN}rclone config${NC} as ${WHOAMI} first."
        exit 1
    fi

    # fuse.conf — user_allow_other needed for Docker containers to see mount
    if grep -q "^user_allow_other" "$FUSE_CONF"; then
        success "user_allow_other already enabled in $FUSE_CONF"
    elif grep -q "^#user_allow_other" "$FUSE_CONF"; then
        warn "user_allow_other is commented out — enabling it..."
        sed -i 's/^#user_allow_other/user_allow_other/' "$FUSE_CONF"
        success "user_allow_other enabled in $FUSE_CONF"
    else
        warn "user_allow_other not found in $FUSE_CONF — appending..."
        echo "user_allow_other" >> "$FUSE_CONF"
        success "user_allow_other added to $FUSE_CONF"
    fi

    # fusermount available
    if command -v fusermount &>/dev/null || command -v fusermount3 &>/dev/null; then
        success "fusermount available"
    else
        die "fusermount not found. Install fuse: sudo apt install fuse"
    fi

    success "All preflight checks passed."
}

# ── Interactive config ───────────────────────────────────────
rcmx_config() {
    section "RCM-X Configuration"

    # Instance name (used for service file naming)
    echo -e "${CYAN}Instance name${NC} ${GRAY}(used for systemd service names, e.g. 'media', 'backup')${NC}"
    read -rp "  → Name: " INSTANCE_NAME
    [[ -z "$INSTANCE_NAME" ]] && die "Instance name cannot be empty."
    # Sanitise: lowercase, alphanumeric + hyphen only
    INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]-' '-' | sed 's/-*$//')

    RCLONE_SERVICE_FILE="rcmx-rclone-${INSTANCE_NAME}.service"
    MERGERFS_SERVICE_FILE="rcmx-mergerfs-${INSTANCE_NAME}.service"
    RCLONE_LOG_FILE="${LOG_DIR}/rclone-${INSTANCE_NAME}.log"

    echo ""

    # Merged directory
    echo -e "${CYAN}MERGED directory${NC} ${GRAY}(union of local + remote — your working path)${NC}"
    read -rp "  → Full path: " MERGED_DIR
    [[ -z "$MERGED_DIR" ]] && die "Merged directory cannot be empty."

    echo ""

    # Local directory
    echo -e "${CYAN}LOCAL directory${NC} ${GRAY}(where new files are written to)${NC}"
    read -rp "  → Full path: " LOCAL_DIR
    [[ -z "$LOCAL_DIR" ]] && die "Local directory cannot be empty."

    echo ""

    # Remote mount point (where rclone will mount on the host)
    echo -e "${CYAN}REMOTE MOUNT directory${NC} ${GRAY}(where rclone will mount the remote on this host)${NC}"
    read -rp "  → Full path: " REMOTE_MOUNT_DIR
    [[ -z "$REMOTE_MOUNT_DIR" ]] && die "Remote mount directory cannot be empty."

    echo ""

    # rclone remote selection
    echo -e "${CYAN}Available rclone remotes:${NC}"
    local remotes
    remotes=$(rclone listremotes --config="$RCLONE_CONF" 2>/dev/null) || die "Failed to list rclone remotes."
    if [[ -z "$remotes" ]]; then
        die "No rclone remotes configured. Run 'rclone config' as $WHOAMI first."
    fi

    local i=1
    local remote_array=()
    while IFS= read -r r; do
        echo -e "    ${WHITE}[$i]${NC} ${r}"
        remote_array+=("$r")
        (( i++ ))
    done <<< "$remotes"

    echo ""
    read -rp "  → Select remote [1-$((i-1))] or type name: " remote_choice

    if [[ "$remote_choice" =~ ^[0-9]+$ ]]; then
        local idx=$(( remote_choice - 1 ))
        [[ $idx -lt 0 || $idx -ge ${#remote_array[@]} ]] && die "Invalid selection: $remote_choice"
        REMOTE="${remote_array[$idx]}"
    else
        # Typed name — validate it exists
        if echo "$remotes" | grep -qF "${remote_choice}:"; then
            REMOTE="${remote_choice}:"
        elif echo "$remotes" | grep -qF "${remote_choice}"; then
            REMOTE="$remote_choice"
        else
            die "Remote not found: $remote_choice"
        fi
    fi
    # Ensure trailing colon
    [[ "$REMOTE" != *: ]] && REMOTE="${REMOTE}:"
    success "Selected remote: $REMOTE"

    echo ""

    # Remote path within the remote
    echo -e "${CYAN}Remote path${NC} ${GRAY}(path within the remote, e.g. 'media' or 'tv'. Leave blank for root)${NC}"
    read -rp "  → Path: " REMOTE_PATH
    REMOTE_PATH="${REMOTE_PATH%/}"  # strip trailing slash

    echo ""

    # VFS cache size
    echo -e "${CYAN}VFS cache max size${NC} ${GRAY}(rclone local cache for remote reads, e.g. 10G, 20G)${NC}"
    read -rp "  → Size [10G]: " VFS_CACHE_SIZE
    VFS_CACHE_SIZE="${VFS_CACHE_SIZE:-10G}"

    # Parallel transfers
    echo -e "${CYAN}Parallel transfers${NC} ${GRAY}(rclone upload/download concurrency)${NC}"
    read -rp "  → Count [4]: " TRANSFERS
    TRANSFERS="${TRANSFERS:-4}"

    echo ""

    # Confirmation summary
    section "Confirm Configuration"
    echo -e "  ${WHITE}Instance name   :${NC} ${CYAN}$INSTANCE_NAME${NC}"
    echo -e "  ${WHITE}Merged dir      :${NC} ${CYAN}$MERGED_DIR${NC}"
    echo -e "  ${WHITE}Local dir       :${NC} ${CYAN}$LOCAL_DIR${NC}"
    echo -e "  ${WHITE}Remote mount    :${NC} ${CYAN}$REMOTE_MOUNT_DIR${NC}"
    echo -e "  ${WHITE}rclone remote   :${NC} ${CYAN}${REMOTE}${REMOTE_PATH}${NC}"
    echo -e "  ${WHITE}VFS cache size  :${NC} ${CYAN}$VFS_CACHE_SIZE${NC}"
    echo -e "  ${WHITE}Transfers       :${NC} ${CYAN}$TRANSFERS${NC}"
    echo -e "  ${WHITE}rclone service  :${NC} ${CYAN}$RCLONE_SERVICE_FILE${NC}"
    echo -e "  ${WHITE}mergerfs service:${NC} ${CYAN}$MERGERFS_SERVICE_FILE${NC}"
    echo -e "  ${WHITE}Log file        :${NC} ${CYAN}$RCLONE_LOG_FILE${NC}"
    echo ""

    read -rp "Continue? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
}

# ── Create directories ───────────────────────────────────────
create_dirs() {
    section "Creating Directories"

    for dir in "$MERGED_DIR" "$LOCAL_DIR" "$REMOTE_MOUNT_DIR" "$LOG_DIR"; do
        if [[ -d "$dir" ]]; then
            success "Already exists: $dir"
        else
            mkdir -p "$dir"
            success "Created: $dir"
        fi
        # Ensure owned by the actual user, not root
        chown "${WHOAMI}:${WHOAMI}" "$dir"
    done

    # Create and set permissions on log file
    touch "$RCLONE_LOG_FILE"
    chown "${WHOAMI}:${WHOAMI}" "$RCLONE_LOG_FILE"
    success "Log file ready: $RCLONE_LOG_FILE"
}

# ── Get user UID/GID ─────────────────────────────────────────
get_user_ids() {
    USER_UID=$(id -u "$WHOAMI")
    USER_GID=$(id -g "$WHOAMI")
}

# ── Write rclone systemd service ─────────────────────────────
write_rclone_service() {
    section "Writing rclone Systemd Service"

    local remote_full="${REMOTE}${REMOTE_PATH}"
    local service_path="${SYSTEMD_DIR}/${RCLONE_SERVICE_FILE}"

    cat > "$service_path" <<EOF
[Unit]
Description=RCM-X rclone mount — ${INSTANCE_NAME}
After=network-online.target
Wants=network-online.target
AssertPathIsDirectory=${REMOTE_MOUNT_DIR}

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount ${remote_full} ${REMOTE_MOUNT_DIR} \\
    --config=${RCLONE_CONF} \\
    --vfs-cache-mode=full \\
    --vfs-cache-max-size=${VFS_CACHE_SIZE} \\
    --vfs-cache-max-age=24h \\
    --vfs-read-chunk-size=128M \\
    --vfs-read-chunk-size-limit=off \\
    --dir-cache-time=72h \\
    --poll-interval=15s \\
    --transfers=${TRANSFERS} \\
    --allow-other \\
    --umask=002 \\
    --uid=${USER_UID} \\
    --gid=${USER_GID} \\
    --log-level=NOTICE \\
    --log-file=${RCLONE_LOG_FILE}
ExecStop=/bin/fusermount -uz ${REMOTE_MOUNT_DIR}
Restart=on-failure
RestartSec=10
User=${WHOAMI}
Group=${WHOAMI}

[Install]
WantedBy=multi-user.target
EOF

    success "Written: $service_path"
}

# ── Write mergerfs systemd service ───────────────────────────
write_mergerfs_service() {
    section "Writing mergerfs Systemd Service"

    local service_path="${SYSTEMD_DIR}/${MERGERFS_SERVICE_FILE}"

    # Detect fusermount version
    local fusermount_bin
    if command -v fusermount3 &>/dev/null; then
        fusermount_bin="fusermount3"
    else
        fusermount_bin="fusermount"
    fi

    cat > "$service_path" <<EOF
[Unit]
Description=RCM-X mergerfs union mount — ${INSTANCE_NAME}
After=${RCLONE_SERVICE_FILE}
Requires=${RCLONE_SERVICE_FILE}
AssertPathIsDirectory=${MERGED_DIR}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mergerfs \\
    ${LOCAL_DIR}:${REMOTE_MOUNT_DIR} \\
    ${MERGED_DIR} \\
    -o defaults,allow_other,use_ino \\
    -o category.create=ff \\
    -o fsname=rcmx-${INSTANCE_NAME} \\
    -o minfreespace=10G \\
    -o umask=002
ExecStop=/bin/${fusermount_bin} -uz ${MERGED_DIR}
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

    success "Written: $service_path"
}

# ── Enable and start services ────────────────────────────────
enable_services() {
    section "Enabling Systemd Services"

    systemctl daemon-reload
    success "systemd daemon reloaded"

    log "Enabling and starting ${RCLONE_SERVICE_FILE}..."
    systemctl enable --now "$RCLONE_SERVICE_FILE" \
        && success "rclone service enabled and started" \
        || die "Failed to start rclone service. Run: journalctl -xeu $RCLONE_SERVICE_FILE"

    # Brief wait for rclone mount to settle before mergerfs
    sleep 3

    log "Enabling and starting ${MERGERFS_SERVICE_FILE}..."
    systemctl enable --now "$MERGERFS_SERVICE_FILE" \
        && success "mergerfs service enabled and started" \
        || die "Failed to start mergerfs service. Run: journalctl -xeu $MERGERFS_SERVICE_FILE"
}

# ── Verify mounts ────────────────────────────────────────────
verify_mounts() {
    section "Verifying Mounts"

    local ok=true

    if mountpoint -q "$REMOTE_MOUNT_DIR"; then
        success "rclone mount active: $REMOTE_MOUNT_DIR"
    else
        error "rclone mount NOT active: $REMOTE_MOUNT_DIR"
        ok=false
    fi

    if mountpoint -q "$MERGED_DIR"; then
        success "mergerfs mount active: $MERGED_DIR"
    else
        error "mergerfs mount NOT active: $MERGED_DIR"
        ok=false
    fi

    if $ok; then
        echo ""
        success "All mounts verified."
        echo ""
        echo -e "  ${WHITE}Write test path :${NC} ${CYAN}$LOCAL_DIR${NC}"
        echo -e "  ${WHITE}Union view      :${NC} ${CYAN}$MERGED_DIR${NC}"
        echo -e "  ${WHITE}Remote read-only:${NC} ${CYAN}$REMOTE_MOUNT_DIR${NC}"
        echo ""
        dim "All new files written to $MERGED_DIR land in $LOCAL_DIR"
        dim "Run rcmv to move local files to remote when ready."
    else
        echo ""
        warn "One or more mounts failed. Check logs:"
        dim "sudo journalctl -xeu $RCLONE_SERVICE_FILE"
        dim "sudo journalctl -xeu $MERGERFS_SERVICE_FILE"
        exit 1
    fi
}

# ── Uninstall mode ───────────────────────────────────────────
uninstall() {
    section "RCM-X Uninstall"

    read -rp "  Instance name to remove: " INSTANCE_NAME
    [[ -z "$INSTANCE_NAME" ]] && die "Instance name required."
    INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]-' '-' | sed 's/-*$//')

    RCLONE_SERVICE_FILE="rcmx-rclone-${INSTANCE_NAME}.service"
    MERGERFS_SERVICE_FILE="rcmx-mergerfs-${INSTANCE_NAME}.service"

    for svc in "$MERGERFS_SERVICE_FILE" "$RCLONE_SERVICE_FILE"; do
        local path="${SYSTEMD_DIR}/${svc}"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" && success "Stopped: $svc"
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" && success "Disabled: $svc"
        fi
        if [[ -f "$path" ]]; then
            rm -f "$path" && success "Removed: $path"
        fi
    done

    systemctl daemon-reload
    success "Uninstall complete for instance: $INSTANCE_NAME"
    warn "Directories and log files were NOT removed. Remove manually if needed."
}

# ── Status mode ──────────────────────────────────────────────
show_status() {
    section "RCM-X Instance Status"

    local found=false
    for f in "${SYSTEMD_DIR}"/rcmx-rclone-*.service; do
        [[ -f "$f" ]] || continue
        found=true
        local name
        name=$(basename "$f" | sed 's/rcmx-rclone-//;s/\.service//')
        echo -e "\n  ${WHITE}Instance:${NC} ${CYAN}$name${NC}"
        systemctl is-active --quiet "rcmx-rclone-${name}.service" \
            && echo -e "    rclone  : ${GREEN}active${NC}" \
            || echo -e "    rclone  : ${RED}inactive${NC}"
        systemctl is-active --quiet "rcmx-mergerfs-${name}.service" \
            && echo -e "    mergerfs: ${GREEN}active${NC}" \
            || echo -e "    mergerfs: ${RED}inactive${NC}"
    done

    $found || echo -e "  ${GRAY}No RCM-X instances found.${NC}"
    echo ""
}

# ── Usage ────────────────────────────────────────────────────
usage() {
    echo -e "\n${WHITE}Usage:${NC} sudo $0 [command]"
    echo ""
    echo -e "  ${CYAN}(no args)${NC}   Run interactive setup"
    echo -e "  ${CYAN}status${NC}      Show all RCM-X instance status"
    echo -e "  ${CYAN}uninstall${NC}   Remove a RCM-X instance"
    echo -e "  ${CYAN}help${NC}        Show this message"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    print_header

    case "${1:-}" in
        status)
            show_status
            exit 0
            ;;
        uninstall)
            [[ $EUID -ne 0 ]] && die "Run with sudo."
            uninstall
            exit 0
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        "")
            apt_checks
            rcmx_config
            get_user_ids
            create_dirs
            write_rclone_service
            write_mergerfs_service
            enable_services
            verify_mounts
            ;;
        *)
            error "Unknown command: ${1:-}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
