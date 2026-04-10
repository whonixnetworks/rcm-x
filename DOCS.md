<p align="center">
  <img src="rcm-x.png" alt="rcm-x logo" width="200"/>
</p>

# RCM-X Technical Documentation

Detailed technical documentation for `rcmx-setup.sh` — the rclone + mergerfs union mount setup script.

---

## Overview

RCM-X creates a union mount combining local storage with cloud storage via rclone. This provides a seamless view where local and remote files appear together, with all writes going to local storage first.

---

## Architecture

### How It Works

RCM-X creates a three-layer architecture:

```
┌─────────────────────────────────────────────────────────┐
│                    MERGED_DIR                          │
│              (Your working directory)                   │
│     ┌──────────────────────────────────────┐           │
│     │  mergerfs union mount                │           │
│     │  • Local files prioritized          │           │
│     │  • Remote files visible               │           │
│     │  • New writes go to LOCAL_DIR       │           │
│     └──────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────┘
                          │
            ┌─────────────┴─────────────┐
            │                           │
┌───────────▼──────────┐    ┌───────────▼──────────┐
│     LOCAL_DIR        │    │   REMOTE_MOUNT_DIR   │
│  (Local storage)     │    │  (rclone mount)     │
│  • Fast writes       │    │  • Cloud access     │
│  • Physical files    │    │  • Cached reads     │
└──────────────────────┘    └───────────┬──────────┘
                                        │
                           ┌────────────▼─────┐
                           │   RCLONE REMOTE   │
                           │  (Cloud storage) │
                           └───────────────────┘
```

**Key behaviors:**
- All writes land in `LOCAL_DIR` first
- Remote files are visible but not writable directly
- The merged view prioritizes local files (same filename = local wins)
- Use `rcmv` to upload local files to remote when ready

---

## Operating Modes

### Standard Mode

In Standard Mode, you manually specify all three directories:

| Directory | Purpose | Example |
|-----------|---------|---------|
| `MERGED_DIR` | Working view — where you interact with files | `~/merged` |
| `LOCAL_DIR` | Local storage — where writes physically land | `~/local` |
| `REMOTE_MOUNT_DIR` | rclone mount point — cloud access | `~/remote` |

**Best for:** Users who want full control over directory placement, or those mounting on network-attached storage.

---

### Merged-only Mode

In Merged-only Mode, you specify only the working directory. RCM-X automatically creates hidden backing directories:

```
~/merged                    ← Your working directory (MERGED_DIR)
└── (local + remote files appear here)

~/.local/share/rcmx/
└── <instance-name>/
    ├── local/              ← Hidden local storage (LOCAL_DIR)
    └── remote/             ← Hidden rclone mount (REMOTE_MOUNT_DIR)
```

**Best for:** Users who want a clean setup with minimal visible directories. Ideal for desktop environments.

**Critical requirement:** The backing directories (`local/` and `remote/`) are placed OUTSIDE the merged mount to prevent a FUSE deadlock. If they were inside, any access would recursively call back into mergerfs.

---

## Systemd Services

RCM-X creates two systemd services per instance:

### rclone Service

File: `/etc/systemd/system/rcmx-rclone-<instance>.service`

**Purpose:** Mounts the cloud remote as a local filesystem.

**Key options:**
- `Type=notify` — rclone signals when ready
- `vfs-cache-mode=full` — Full caching for better performance
- `vfs-cache-max-size` — User-configurable (default: 10G)
- `allow-other` — Other users can access the mount
- `uid/gid` — Files appear owned by the setup user
- `umask=002` — Permissions for shared access

**Timeout settings:**
- `TimeoutStartSec=60` — Wait up to 60s for mount
- `TimeoutStopSec=30` — Wait up to 30s for clean unmount

---

### mergerfs Service

File: `/etc/systemd/system/rcmx-mergerfs-<instance>.service`

**Purpose:** Creates the union mount combining local + remote.

**Dependencies:**
- `After=rcmx-rclone-<instance>.service` — Starts after rclone
- `Requires=rcmx-rclone-<instance>.service` — Stops if rclone stops

**Key options:**
- `category.create=ff` — "First found" — new files go to first branch (local)
- `fsname=rcmx-<instance>` — Custom filesystem name
- `minfreespace=10G` — Minimum free space on local branch
- `umask=002` — Consistent permissions

---

## Instance Management

RCM-X supports multiple independent instances. Each instance has:
- A unique name (e.g., "media", "backup", "documents")
- Separate systemd services
- Separate mount points
- Separate log files

**Service file naming:**
- `rcmx-rclone-<instance>.service`
- `rcmx-mergerfs-<instance>.service`

**Log file:**
- `/var/log/rcmx/rclone-<instance>.log`

---

## FUSE Deadlock Prevention

RCM-X implements multiple safeguards against FUSE deadlocks:

### 1. Mount Conflict Detection

Before setup, the script checks:
- If target directories are already mount points
- If child directories of the merged directory are mounted
- If backing directories would end up inside the mergerfs mount (merged-only mode)

### 2. Timeout-based Mount Checks

The `mountpoint_with_timeout()` function uses `timeout` to prevent hangs:
```bash
# Fails after 3 seconds instead of hanging forever
timeout 3 bash -c "mountpoint -q '$dir'"
```

### 3. /proc/mounts Parsing

The `check_mount_in_proc()` function reads `/proc/mounts` directly, which never hangs even on stuck FUSE mounts:
```bash
grep -q " $normalized_dir " /proc/mounts
```

### 4. Safe Shutdown Sequence

Services stop in correct order:
1. Stop mergerfs first (depends on rclone mount)
2. Stop rclone last
3. Wait for actual unmount with timeout (30s max)

---

## Shell Aliases

After installation, the following aliases are added to your shell config:

| Alias | Command |
|-------|---------|
| `rcmx` | `sudo /usr/local/bin/rcmx` |
| `rcmx-status` | `sudo /usr/local/bin/rcmx status` |
| `rcmx-start` | `sudo /usr/local/bin/rcmx start` |
| `rcmx-stop` | `sudo /usr/local/bin/rcmx stop` |
| `rcmx-restart` | `sudo /usr/local/bin/rcmx restart` |
| `rcmx-logs` | `sudo /usr/local/bin/rcmx logs` |
| `rcmx-uninstall` | `sudo /usr/local/bin/rcmx uninstall` |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_NAME` | user-defined | Identifier for this mount setup |
| `MERGED_DIR` | `~/merged` | Working directory (union view) |
| `LOCAL_DIR` | `~/local` or `~/.local/share/rcmx/<name>/local` | Local storage path |
| `REMOTE_MOUNT_DIR` | `~/remote` or `~/.local/share/rcmx/<name>/remote` | rclone mount point |
| `REMOTE` | user-selected | rclone remote name (e.g., `gdrive:`) |
| `REMOTE_PATH` | empty | Subfolder within remote (optional) |
| `VFS_CACHE_SIZE` | `10G` | rclone VFS cache limit |
| `TRANSFERS` | `4` | Concurrent rclone transfers |

---

## Security Considerations

<details>
<summary>File Permissions</summary>

- Mount directories are owned by the user who ran setup
- `umask=002` allows group read/write
- Services run as the user, not root (via `User=` in systemd)
- The `user_allow_other` fuse option allows Docker containers to see mounts

</details>

<details>
<summary>Encrypted Remotes</summary>

RCM-X supports encrypted rclone remotes (crypt, GCrypt). When selecting a remote:
- Choose the encrypted remote (e.g., `gcrypt:`)
- Not the underlying storage (e.g., `gdrive:`)
- Files are decrypted on-the-fly by rclone

</details>

---

## Troubleshooting

<details>
<summary>Mount not starting</summary>

**Check service status:**
```bash
sudo systemctl status rcmx-rclone-<instance>
sudo systemctl status rcmx-mergerfs-<instance>
```

**Check logs:**
```bash
sudo journalctl -xeu rcmx-rclone-<instance>
sudo journalctl -xeu rcmx-mergerfs-<instance>
```

**Common causes:**
- Remote name incorrect — run `rclone listremotes` to verify
- Network unreachable — check connectivity
- Authentication expired — re-run `rclone config`

</details>

<details>
<summary>Mount appears stuck</summary>

**Force unmount:**
```bash
sudo fusermount -uz /path/to/merged
cd /path/to/merged  # Trigger cleanup
```

**Restart services:**
```bash
sudo rcmx restart
```

</details>

<details>
<summary>Docker containers can't see mounts</summary>

Ensure `user_allow_other` is enabled in `/etc/fuse.conf`:
```bash
grep user_allow_other /etc/fuse.conf
```

Restart the mount:
```bash
sudo rcmx restart
```

</details>

---

## File Locations

| File | Path | Description |
|------|------|-------------|
| Script | `/usr/local/bin/rcmx` | Installed command |
| rclone config | `~/.config/rclone/rclone.conf` | Remote definitions |
| fuse config | `/etc/fuse.conf` | FUSE settings |
| Service files | `/etc/systemd/system/rcmx-*.service` | Systemd units |
| Logs | `/var/log/rcmx/rclone-<instance>.log` | rclone output |

---

## License

MIT License - see [LICENSE](LICENSE) for details.
