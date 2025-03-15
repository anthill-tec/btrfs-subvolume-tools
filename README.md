# BTRFS Subvolume Tools

A collection of tools for managing btrfs subvolumes and snapshots, focused on easy creation, configuration, and maintenance of subvolumes on existing systems.

## Overview

BTRFS Subvolume Tools provides utilities to simplify the creation and management of btrfs subvolumes and snapshots. The toolkit includes two primary tools:

### create-subvolume

Handles the complete workflow for setting up new subvolumes including:
- Data backup
- Subvolume creation
- Data restoration
- System configuration (fstab updates)

### configure-snapshots

Manages snapper configuration for automatic snapshots:
- Configuration of snapper for any btrfs subvolume
- Setting up retention policies for snapshots
- Configuring user permissions
- Setting up systemd timers and pacman hooks

The tools are designed to be safe, robust, and friendly to use both in normal operation and during emergency recovery scenarios.

## Installation

### Using Make

```bash
git clone https://github.com/yourusername/btrfs-subvolume-tools.git
cd btrfs-subvolume-tools
make
sudo make install
```

By default, this installs to `/usr/local`. To change the installation prefix:

```bash
sudo make install PREFIX=/usr
```

### Using Install Script

```bash
git clone https://github.com/yourusername/btrfs-subvolume-tools.git
cd btrfs-subvolume-tools
sudo ./install.sh
```

To use a different installation location:

```bash
sudo PREFIX=/usr ./install.sh
```

## Usage

### Creating a Subvolume

Basic usage with defaults (creates @home subvolume for /home):

```bash
sudo create-subvolume
```

Create a subvolume with backup:

```bash
sudo create-subvolume --backup
```

Create a subvolume for a different mount point:

```bash
sudo create-subvolume --target-mount /var --subvol-name @var
```

Custom backup location:

```bash
sudo create-subvolume --backup --backup-drive /dev/sdc1 --backup-mount /mnt/mybackup
```

### Configuring Snapshots

Configure snapper for a subvolume with default settings:

```bash
sudo configure-snapshots --target-mount /home
```

Allow specific users to manage snapshots:

```bash
sudo configure-snapshots --target-mount /home --allow-users john,mary
```

Custom snapshot retention policy:

```bash
sudo configure-snapshots --hourly 10 --daily 14 --weekly 8
```

Update existing configuration without prompting:

```bash
sudo configure-snapshots --target-mount /home --allow-users alex,sam --force
```

### Running in Emergency Mode

For system directories like /home, /var, etc., it's recommended to run from an emergency shell when creating subvolumes:

1. Boot to emergency shell (add `systemd.unit=emergency.target` to kernel parameters)
2. Remount root as read-write: `mount -o remount,rw /`
3. Run the script: `create-subvolume [OPTIONS]`

See the man pages for detailed instructions for different boot loaders (GRUB, rEFInd, systemd-boot).

## Command-Line Options

### create-subvolume

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-b, --backup` | Perform backup before creating subvolume |
| `-d, --backup-drive DEVICE` | Backup drive device (default: /dev/sdb3) |
| `-m, --backup-mount MOUNTPOINT` | Backup mount point (default: /tmp/home_backup) |
| `-t, --target-device DEVICE` | Target device to modify (default: /dev/nvme1n1p2) |
| `-p, --target-mount MOUNTPOINT` | Target mount point (default: /home) |
| `-s, --subvol-name NAME` | Subvolume name (default: @home) |

### configure-snapshots

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-p, --target-mount MOUNTPOINT` | Target mount point (default: /home) |
| `-c, --config-name NAME` | Configuration name (default: basename of mount point) |
| `-u, --allow-users USERS` | Comma-separated list of users allowed to use snapper |
| `-t, --timeline BOOL` | Enable timeline snapshots (default: yes) |
| `-f, --force` | Force update of existing configurations without prompting |
| `--hourly NUMBER` | Number of hourly snapshots to keep (default: 5) |
| `--daily NUMBER` | Number of daily snapshots to keep (default: 7) |
| `--weekly NUMBER` | Number of weekly snapshots to keep (default: 4) |
| `--monthly NUMBER` | Number of monthly snapshots to keep (default: 6) |
| `--yearly NUMBER` | Number of yearly snapshots to keep (default: 0) |
| `--no-pacman-hooks` | Don't install or configure pacman hooks |
| `--no-timers` | Don't enable systemd timers for snapper |

## Typical Workflow

1. **Create btrfs subvolumes**:
   ```bash
   sudo create-subvolume --target-mount /home --subvol-name @home --backup
   ```

2. **Configure snapper for the new subvolume**:
   ```bash
   sudo configure-snapshots --target-mount /home --allow-users myusername
   ```

3. **Verify configuration**:
   ```bash
   snapper -c home list
   ```

## Safety Features

- Verification of all devices, mount points, and subvolumes
- Backup of original fstab and snapper configurations
- Temporary mount handling with restoration of previous mounts
- Detection of processes using mount points
- Empty backup detection and confirmation
- Intelligent error handling at each step
- Confirmation prompts before modifying existing configurations

## Requirements

- btrfs-progs
- bash
- util-linux (for mount, lsblk, etc.)
- snapper (for snapshot management)
- snap-pac (optional, for pacman hooks on Arch Linux)
- Optionally pandoc (for man page generation)

## License

This project is licensed under the GNU General Public License v3.0 - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch: `git checkout -b feature/amazing-feature`
3. Commit your changes: `git commit -m 'Add some amazing feature'`
4. Push to the branch: `git push origin feature/amazing-feature`
5. Open a Pull Request
