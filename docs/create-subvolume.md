% CREATE-SUBVOLUME(8) v1.0 | System Administration Commands
%
% March 2025

# NAME

create-subvolume - Create and configure btrfs subvolumes

# SYNOPSIS

**create-subvolume** [OPTIONS]

# DESCRIPTION

**create-subvolume** is a utility script for creating btrfs subvolumes and configuring the system to use them. It handles the complete workflow of backing up existing data, creating a new subvolume, copying data to it, and updating the system configuration.

This tool is particularly useful when setting up a new subvolume layout on an existing btrfs filesystem. It can be run from both a normal system environment or an emergency/rescue shell.

# OPTIONS

**-h, --help**
: Show help message and exit

**-b, --backup**
: Perform backup before creating subvolume

**-d, --backup-drive** *DEVICE*
: Specify backup drive device (default: /dev/sdb3)

**-m, --backup-mount** *MOUNTPOINT*
: Specify backup mount point (default: /tmp/home_backup)

**-t, --target-device** *DEVICE*
: Specify target device to modify (default: /dev/nvme1n1p2)

**-p, --target-mount** *MOUNTPOINT*
: Specify target mount point (default: /home)

**-s, --subvol-name** *NAME*
: Specify subvolume name (default: @home)

**-n, --non-interactive**
: Run without prompting for user input

### Backup Options

**--backup-method=METHOD**
: Specify the method for copying data:

- `tar`: Use tar with pv for compression and progress (requires: tar, pv)
- `parallel`: Use GNU parallel for multi-threaded copying (requires: parallel)
- (Automatically falls back if dependencies not met)

**--error-handling=MODE**
: Specify how to handle file copy errors:

- `strict`: Stop on first error (default)
- `continue`: Skip problem files and continue

**--backup-extra-opts="OPTS"**
: Additional options to pass to the backup command
  (Use with caution, options are passed directly to do-backup.sh)

# RUNNING FROM EMERGENCY SHELL

To properly create subvolumes on system mountpoints like /home, /var, etc., it's recommended to run this script from an emergency shell. This ensures no processes are using the target mountpoint during the operation.

## Emergency Shell Preparation

1. **Boot to emergency shell**:

   **For GRUB**:

   - During the GRUB boot menu, press 'e' to edit the boot entry
   - Find the line starting with 'linux' or 'linux16'
   - Add `systemd.unit=emergency.target` to the end of this line
   - Press Ctrl+X or F10 to boot

   **For rEFInd**:

   - At the rEFInd boot menu, select your Linux distribution
   - Press Tab or F2 to edit the boot options
   - Add `systemd.unit=emergency.target` to the options
   - Press Enter to boot

   **For systemd-boot**:

   - At the systemd-boot menu, press 'e' to edit the selected entry
   - Add `systemd.unit=emergency.target` to the end of the kernel command line
   - Press Enter to boot with the modified options
   - Alternatively, for one-time use, you can hold the space bar during boot to enter the boot menu, select an entry, and press 'd' to add kernel parameters

2. **Remount root filesystem as read-write**:

   ```
   mount -o remount,rw /
   ```

3. **Ensure network if needed**:

   ```
   systemctl start systemd-networkd
   ```

4. **Run the script**:

   ```
   create-subvolume.sh [OPTIONS]
   ```

# EXAMPLES

Create a subvolume for /home with default settings:

```
create-subvolume.sh
```

Create a subvolume with backup:

```
create-subvolume.sh --backup
```

Create a subvolume for /var:

```
create-subvolume.sh --target-mount /var --subvol-name @var
```

Create a subvolume with custom backup location:

```
create-subvolume.sh --backup --backup-drive /dev/sdc1 --backup-mount /mnt/mybackup
```

Create a subvolume with parallel backup method and continue on errors:

```
create-subvolume.sh --backup --backup-method=parallel --error-handling=continue
```

Create a subvolume with custom backup options:

```
create-subvolume.sh --backup --backup-extra-opts="--exclude=/home/user/tmp"
```

# WORKFLOW

The script performs the following operations:

1. Checks prerequisites and verifies devices
2. Handles backup operations if requested
3. Prepares the target mount (unmounts if necessary)
4. Creates the subvolume and copies data
5. Updates system configuration (fstab entries)
6. Cleans up temporary mounts and finalizes configuration

# CONSIDERATIONS

**Root Privileges**
: This script must be run with root privileges.

**Filesystem Type**
: Both target and backup devices must be accessible and properly formatted.

**Emergency Mode**
: Running from emergency mode is strongly recommended for system directories.

**Backups**
: Always have additional backups before running major filesystem operations.

# FILES

*/etc/fstab*
: Modified to include the new subvolume mount configuration

*/etc/fstab.bak*
: Backup of the original fstab file

# NOTES

This script uses the btrfs reflink feature to efficiently copy data when both source and destination are on btrfs filesystems. This significantly speeds up the copy process and reduces disk space usage.

# SEE ALSO

btrfs(8), btrfs-subvolume(8), do-backup(8), mount(8), fstab(5)

# AUTHOR

This man page and script are provided as a utility for btrfs filesystem management.
