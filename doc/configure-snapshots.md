% CONFIGURE-SNAPSHOTS(8) v1.0 | System Administration Commands
% 
% March 2025

# NAME

configure-snapshots - Configure snapper for btrfs subvolumes

# SYNOPSIS

**configure-snapshots** [OPTIONS]

# DESCRIPTION

**configure-snapshots** is a utility script for configuring snapper to manage snapshots for btrfs subvolumes. It automates the setup of snapper configurations, systemd timers, and pacman hooks (on Arch Linux) to provide a comprehensive snapshot solution.

This tool is designed to complement the **create-subvolume** script, providing the snapshot management functionality after subvolumes have been created.

# OPTIONS

**-h, --help**
: Show help message and exit

**-p, --target-mount** *MOUNTPOINT*
: Target mount point to configure snapper for (default: /home)

**-c, --config-name** *NAME*
: Configuration name (default: basename of mount point)

**-u, --allow-users** *USERS*
: Comma-separated list of users allowed to use snapper

**-t, --timeline** *BOOL*
: Enable timeline snapshots (default: yes)

**-f, --force**
: Force update of existing configurations without prompting

**--hourly** *NUMBER*
: Number of hourly snapshots to keep (default: 5)

**--daily** *NUMBER*
: Number of daily snapshots to keep (default: 7)

**--weekly** *NUMBER*
: Number of weekly snapshots to keep (default: 4)

**--monthly** *NUMBER*
: Number of monthly snapshots to keep (default: 6)

**--yearly** *NUMBER*
: Number of yearly snapshots to keep (default: 0)

**--no-pacman-hooks**
: Don't install or configure pacman hooks

**--no-timers**
: Don't enable systemd timers for snapper

# EXAMPLES

Configure snapper for /home with default settings:
```
configure-snapshots
```

Allow specific users to manage snapshots:
```
configure-snapshots --target-mount /home --allow-users john,mary
```

Configure snapper for /var with a custom configuration name:
```
configure-snapshots --target-mount /var --config-name var
```

Disable timeline snapshots but keep pacman hooks:
```
configure-snapshots --timeline no
```

Configure snapper with custom snapshot retention:
```
configure-snapshots --hourly 10 --daily 14 --weekly 8
```

Update existing configuration without confirmation prompt:
```
configure-snapshots --target-mount /home --allow-users alex,sam --force
```

# WORKFLOW

The script performs the following operations:

1. Checks prerequisites (root privileges, snapper installation)
2. Verifies the target mount point is a btrfs subvolume
3. Creates or updates the snapper configuration (with confirmation for existing configs)
4. Sets up systemd timers for automatic snapshots
5. Configures pacman hooks (on Arch Linux)
6. Creates an initial snapshot

# CONSIDERATIONS

**Root Privileges**
: This script must be run with root privileges.

**Filesystem Type**
: The target mount point must be a btrfs subvolume, not just any btrfs mount point.

**Pacman Hooks**
: Pacman hooks are only configured on Arch Linux-based systems.

**Users**
: Users specified with --allow-users can manage snapshots without root privileges.

**Existing Configurations**
: The script will prompt before modifying existing configurations unless --force is used.

# FILES

*/etc/snapper/configs/$CONFIG_NAME*
: The snapper configuration file that will be created or modified

*/etc/snapper/configs/$CONFIG_NAME.bak*
: Backup of the original snapper configuration file

# NOTES

Snapper provides powerful snapshot management for btrfs filesystems, including:

- Regular automatic snapshots (timeline)
- Pre/post snapshots for package installations (via pacman hooks)
- Easy snapshot comparison, viewing, and rollback

After running this script, you can manage snapshots using the snapper command:

```
snapper -c CONFIG_NAME list
snapper -c CONFIG_NAME create -d "description"
snapper -c CONFIG_NAME delete NUMBER
```

# SEE ALSO

snapper(8), btrfs(8), create-subvolume(8), btrfs-subvolume(8)

# AUTHOR

This man page and script are provided as utilities for btrfs filesystem management.
