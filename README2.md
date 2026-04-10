<p align="center">
  <img src="rcm-x.png" alt="rcm-x logo" width="200"/>
</p>

# RCM-X

`rcm-x` ~ A collection of bash scripts aimed to easily mount [rclone](https://rclone.org) remotes to a unix/linux os.

----

## rcmx-setup.sh

<details>
<summary>Interactive RCM-X Setup Script (click to expand)</summary>

The `rcmx-setup.sh` script provides an interactive setup experience for creating rclone + mergerfs union mounts. Key features include:

- **Interactive Configuration**: Guided setup for instance name, mode selection, directories, remote selection, and performance tuning
- **Two Modes Available**:
  - Standard Mode: Choose separate directories for working view, local storage, and remote mount
  - Merged-only Mode: Specify one working directory with local storage and remote mount hidden in a private subfolder
- **Automatic Dependency Handling**: Checks and installs required dependencies (mergerfs, rclone, fuse)
- **Systemd Service Creation**: Generates and enables systemd services for both rclone and mergerfs mounts
- **Service Management**: Built-in commands for starting, stopping, restarting, checking status, viewing logs, and uninstalling instances

### Usage

Run the script interactively:
```bash
./rcmx-setup.sh
```

Available commands after installation:
- `rcmx` - Run interactive setup
- `rcmx start` - Start rclone + mergerfs services
- `rcmx stop` - Stop mergerfs + rclone services
- `rcmx restart` - Restart both services
- `rcmx status` - Show all instance status
- `rcmx logs` - Show logs for an instance
- `rcmx uninstall` - Remove an instance

### Features

- Automatic UID/GID detection for proper file permissions
- Mount conflict detection and prevention
- Support for encrypted remotes (GCrypt, crypt)
- Configurable VFS cache size and parallel transfers
- Logging to both systemd journal and dedicated log files
- Shell alias installation for easy access
</details>

----

## rcmv/rcmv

<details>
<summary>RCMV - Rclone Move Utility (click to expand)</summary>

Extra script for specific use cases: Uses `rclone move` to upload local files to a remote.

- Efficiently moves local files to cloud storage
- Preserves directory structure during transfer
- Can be used alongside RCM-X for uploading files from local storage to remote
- Designed to work with the local storage directory created by RCM-X setup

See [rcmv/README.md](rcmv/README.md) for detailed usage information.
</details>

----

## rcmnt/rcmnt

<details>
<summary>RCMNT - Rclone Mount Utility (click to expand)</summary>

Extra script for specific use cases: Provides basic `rclone mount` functionality.

- Simple mounting of rclone remotes to local filesystem
- Useful for direct access to cloud storage without mergerfs union
- Lightweight alternative when union mounts aren't needed

See [rcmnt/README.md](rcmnt/README.md) for detailed usage information.
</details>

----

## Related Projects

- [rclone](https://rclone.org) - The cloud storage synchronization tool
- [mergerfs](https://github.com/trapexit/mergerfs) - Feature-rich union filesystem

## License

This project is licensed under the MIT License - see the LICENSE file for details.