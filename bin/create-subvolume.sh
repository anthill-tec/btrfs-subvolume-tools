#!/bin/bash
set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values configured for /home partition
BACKUP_DRIVE="/dev/sdb3"
BACKUP_MOUNT="/tmp/home_backup"
TARGET_DEVICE="/dev/nvme1n1p2"
TARGET_MOUNT="/home"
SUBVOL_NAME="@home"
DO_BACKUP=false

#
# Utility functions
#

# Show help
show_help() {
  echo -e "${BLUE}Script for creating a btrfs subvolume${NC}"
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -h, --help             Show this help message"
  echo "  -b, --backup           Perform backup before creating subvolume"
  echo "  -d, --backup-drive     Backup drive device (default: $BACKUP_DRIVE)"
  echo "  -m, --backup-mount     Backup mount point (default: $BACKUP_MOUNT)"
  echo "  -t, --target-device    Target device to modify (default: $TARGET_DEVICE)"
  echo "  -p, --target-mount     Target mount point (default: $TARGET_MOUNT)"
  echo "  -s, --subvol-name      Subvolume name (default: $SUBVOL_NAME)"
  echo
  echo "Example:"
  echo "  $0 --backup --backup-drive /dev/sdc1 --subvol-name @myhome"
  echo "  $0 --target-mount /var --subvol-name @var"
  echo
}

# Check if running as root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
  fi
}

# Mount the target device if needed
mount_target_if_needed() {
  local mount_point="$1"
  local device="$2"
  
  # Check if mount point exists
  if [ ! -d "$mount_point" ]; then
    echo -e "${YELLOW}Mount point $mount_point does not exist. Creating it...${NC}"
    mkdir -p "$mount_point" || {
      echo -e "${RED}Failed to create mount point $mount_point${NC}"
      return 1
    }
  fi
  
  # Check if already mounted
  if mountpoint -q "$mount_point"; then
    # Verify correct device is mounted
    local current_device=$(findmnt -n -o SOURCE "$mount_point")
    if [ "$current_device" != "$device" ]; then
      echo -e "${RED}Error: $mount_point is mounted from $current_device, not $device${NC}"
      return 1
    fi
    echo -e "${GREEN}$mount_point is already correctly mounted from $device${NC}"
    return 0
  else
    # Not mounted, mount it
    echo -e "${YELLOW}$mount_point is not mounted. Mounting $device to $mount_point...${NC}"
    mount "$device" "$mount_point" || {
      echo -e "${RED}Failed to mount $device to $mount_point${NC}"
      return 1
    }
    echo -e "${GREEN}Successfully mounted $device to $mount_point${NC}"
    return 0
  fi
}

# Set up temporary mount
setup_temp_mount() {
  local device="$1"
  local mount_point="/mnt"
  
  echo -e "${YELLOW}Setting up temporary mount point at $mount_point${NC}"
  
  # Check if /mnt is already in use
  if mountpoint -q "$mount_point"; then
    # List current mounts on /mnt
    echo -e "${YELLOW}Warning: $mount_point is currently in use with the following mounts:${NC}"
    mount | grep "$mount_point" | sed 's/^/  /'
    
    read -p "Would you like to unmount these and proceed? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${RED}Operation cancelled${NC}"
      return 1
    fi
    
    # Save current mounts for later restoration
    mount | grep "$mount_point" > "/tmp/mnt_previous_mounts.txt"
    
    # Unmount all mounts under /mnt
    umount -R "$mount_point" || {
      echo -e "${RED}Failed to unmount $mount_point. Please free it manually and try again.${NC}"
      return 1
    }
    echo -e "${GREEN}Successfully unmounted all mounts from $mount_point${NC}"
  fi
  
  echo -e "${YELLOW}Mounting target partition to temporary location${NC}"
  mount "$device" "$mount_point" || { 
    echo -e "${RED}Failed to mount target partition to $mount_point${NC}"
    return 1
  }
  echo -e "${GREEN}Target partition mounted at $mount_point${NC}"
  
  # Return the mount point
  echo "$mount_point"
}

# Clean up and restore temporary mount
cleanup_temp_mount() {
  local mount_point="$1"
  
  echo -e "${YELLOW}Unmounting temporary mount at $mount_point${NC}"
  umount "$mount_point" || { 
    echo -e "${RED}Failed to unmount temporary mount${NC}"
    return 1
  }
  echo -e "${GREEN}Temporary mount unmounted${NC}"

  # Check if any previous mounts need to be restored
  if [ -f "/tmp/mnt_previous_mounts.txt" ]; then
    echo -e "${YELLOW}Restoring previous mounts on $mount_point${NC}"
    while read -r mount_line; do
      # Extract device and mount point
      device=$(echo "$mount_line" | awk '{print $1}')
      mountpoint=$(echo "$mount_line" | awk '{print $3}')
      
      if [[ "$mountpoint" == "$mount_point"* ]]; then
        echo -e "${YELLOW}Restoring: $device to $mountpoint${NC}"
        mount "$device" "$mountpoint" || {
          echo -e "${RED}Warning: Failed to restore mount: $device to $mountpoint${NC}"
        }
      fi
    done < "/tmp/mnt_previous_mounts.txt"
    
    rm "/tmp/mnt_previous_mounts.txt"
  fi
  return 0
}

# Update fstab with the new subvolume
update_fstab() {
  local device="$1"
  local mount_point="$2"
  local subvol="$3"
  
  echo -e "${YELLOW}Updating fstab to use $subvol subvolume${NC}"
  
  # Create backup of fstab
  cp /etc/fstab /etc/fstab.bak
  echo -e "${GREEN}Created backup of fstab at /etc/fstab.bak${NC}"

  # Extract UUID for the device
  local device_uuid=$(blkid -s UUID -o value "$device")
  if [ -z "$device_uuid" ]; then
    echo -e "${RED}Error: Could not determine UUID for $device${NC}"
    return 1
  fi

  # Update fstab entry
  if grep -q "$mount_point" /etc/fstab; then
    # Remove any existing subvol option
    sed -i "/$mount_point/ s/subvol=[^,]*,\?//g" /etc/fstab
    # Add new subvol option
    sed -i "/$mount_point/ s/\(defaults[^[:space:]]*\)/subvol=$subvol,\1/g" /etc/fstab
  else
    # If no entry exists, create a new one
    echo "UUID=$device_uuid $mount_point btrfs subvol=$subvol,defaults,noatime 0 0" >> /etc/fstab
  fi

  echo -e "${GREEN}Updated fstab to use $subvol subvolume${NC}"
  echo -e "${YELLOW}Here is the new fstab entry for $mount_point:${NC}"
  grep "$mount_point" /etc/fstab
  return 0
}

#
# Main phase functions 
#

# Phase 1: Check environment and prerequisites
check_prerequisites() {
  echo -e "${BLUE}Phase 1: Checking prerequisites${NC}"
  
  # Check if running as root
  check_root

  # Safety check - verify devices exist and are available
  if [ ! -b "$TARGET_DEVICE" ]; then
    echo -e "${RED}Error: $TARGET_DEVICE (target device) not found${NC}"
    exit 1
  fi

  if ! lsblk "$TARGET_DEVICE" &>/dev/null; then
    echo -e "${RED}Error: $TARGET_DEVICE is not available or accessible${NC}"
    exit 1
  fi

  if [ ! -b "$BACKUP_DRIVE" ]; then
    echo -e "${RED}Error: $BACKUP_DRIVE (backup device) not found${NC}"
    exit 1
  fi

  if ! lsblk "$BACKUP_DRIVE" &>/dev/null; then
    echo -e "${RED}Error: $BACKUP_DRIVE is not available or accessible${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Prerequisites checked successfully${NC}"
}

# Phase 2: Handle backup
handle_backup() {
  echo -e "${BLUE}Phase 2: Handling backup${NC}"
  
  # Create backup mount directory if it doesn't exist
  if [ ! -d "$BACKUP_MOUNT" ]; then
    echo -e "${YELLOW}Creating $BACKUP_MOUNT directory${NC}"
    mkdir -p "$BACKUP_MOUNT"
  fi

  # Mount the backup drive if it's not already mounted
  if ! mountpoint -q "$BACKUP_MOUNT"; then
    echo -e "${YELLOW}Mounting backup drive to $BACKUP_MOUNT${NC}"
    mount "$BACKUP_DRIVE" "$BACKUP_MOUNT" || { 
      echo -e "${RED}Failed to mount backup drive${NC}"
      exit 1
    }
    echo -e "${GREEN}Backup drive mounted successfully${NC}"
  else
    echo -e "${GREEN}Backup drive already mounted at $BACKUP_MOUNT${NC}"
  fi

  # Handle based on backup setting
  if [ "$DO_BACKUP" = true ]; then
    # Mount target for backup if needed
    echo -e "${YELLOW}Checking if target mount is ready for backup...${NC}"
    mount_target_if_needed "$TARGET_MOUNT" "$TARGET_DEVICE" || {
      echo -e "${RED}Cannot proceed with backup without properly mounted target${NC}"
      exit 1
    }
    
    # Verify that target filesystem is btrfs
    FS_TYPE=$(findmnt -n -o FSTYPE "$TARGET_MOUNT")
    if [ "$FS_TYPE" != "btrfs" ]; then
      echo -e "${RED}Error: $TARGET_MOUNT is not a btrfs filesystem (found: $FS_TYPE)${NC}"
      exit 1
    fi
    
    # Perform backup
    echo -e "${YELLOW}Starting backup of $TARGET_MOUNT to $BACKUP_MOUNT${NC}"
    echo -e "${YELLOW}This may take a long time depending on the amount of data...${NC}"
    
    # Create timestamp for backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$BACKUP_MOUNT/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    
    # Use cp with reflink for efficiency on btrfs
    cp -a --reflink=auto "$TARGET_MOUNT"/* "$BACKUP_DIR"/ || { 
      echo -e "${RED}Backup failed${NC}"
      exit 1
    }
    
    echo -e "${GREEN}Backup completed successfully to $BACKUP_DIR${NC}"
    
    # Update backup path to use the new timestamped backup
    BACKUP_SOURCE="$BACKUP_DIR"
  else
    # Use existing backup
    echo -e "${YELLOW}Using existing backup at $BACKUP_MOUNT${NC}"
    BACKUP_SOURCE="$BACKUP_MOUNT"
    
    # Verify backup is actually there - note: we don't exit here as we'll ask for confirmation later
    if [ ! "$(ls -A "$BACKUP_SOURCE" 2>/dev/null)" ]; then
      echo -e "${YELLOW}Warning: Backup directory appears to be empty.${NC}"
    fi
  fi
  
  echo -e "${GREEN}Backup handling completed${NC}"
}

# Phase 3: Prepare the target mount
prepare_target() {
  echo -e "${BLUE}Phase 3: Preparing target mount${NC}"
  
  # Check if target is mounted
  if mountpoint -q "$TARGET_MOUNT"; then
    echo -e "${YELLOW}Target $TARGET_MOUNT is currently mounted. It will be unmounted.${NC}"
    
    # Find processes using target mount
    PROCS=$(lsof "$TARGET_MOUNT" 2>/dev/null)
    if [ -n "$PROCS" ]; then
      echo -e "${RED}Processes still using $TARGET_MOUNT:${NC}"
      echo "$PROCS"
      echo -e "${YELLOW}It's recommended to run this script in emergency mode.${NC}"
      read -p "Continue anyway? (y/n): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Operation cancelled${NC}"
        exit 1
      fi
    fi

    # Unmount target
    echo -e "${YELLOW}Unmounting $TARGET_MOUNT${NC}"
    umount "$TARGET_MOUNT" || { 
      echo -e "${RED}Failed to unmount $TARGET_MOUNT - processes may still be using it${NC}"
      exit 1
    }
    echo -e "${GREEN}Successfully unmounted $TARGET_MOUNT${NC}"
  else
    echo -e "${GREEN}Target $TARGET_MOUNT is not mounted, which is good for subvolume creation${NC}"
  fi
  
  # Set up temporary mount
  TEMP_MOUNT=$(setup_temp_mount "$TARGET_DEVICE")
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to set up temporary mount. Exiting.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Target preparation completed${NC}"
  # Return the temporary mount path
  echo "$TEMP_MOUNT"
}

# Phase 4: Create subvolume and copy data
create_subvolume() {
  local temp_mount="$1"
  
  echo -e "${BLUE}Phase 4: Creating subvolume and copying data${NC}"
    
  # Make sure temp_mount exists and is valid
  if [ -z "$temp_mount" ] || [ ! -d "$temp_mount" ]; then
    echo -e "${RED}Error: Invalid temporary mount path: $temp_mount${NC}"
    return 1
  fi
  
  # Create the subvolume with full path validation
  echo -e "${YELLOW}Creating $SUBVOL_NAME subvolume${NC}"
  local subvol_path="$temp_mount/$SUBVOL_NAME"
  
  echo -e "${YELLOW}Creating subvolume at: $subvol_path${NC}"  # Add this debug line
  
  btrfs subvolume create "$subvol_path" || { 
    echo -e "${RED}Failed to create $SUBVOL_NAME subvolume${NC}"
    return 1
  }
  echo -e "${GREEN}$SUBVOL_NAME subvolume created successfully${NC}"

  # Copy data to the subvolume
  echo -e "${YELLOW}Copying data from backup to $SUBVOL_NAME subvolume${NC}"
  echo -e "${YELLOW}This may take some time depending on the amount of data...${NC}"

  # Check if backup is empty and ask for confirmation
  if [ -z "$(ls -A "$BACKUP_SOURCE")" ]; then
    echo -e "${RED}Warning: Backup directory appears to be empty.${NC}"
    read -p "Continue with empty backup? This will create an empty subvolume (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${RED}Operation cancelled${NC}"
      return 1
    fi
    echo -e "${YELLOW}Proceeding with empty backup...${NC}"
  else
    # Copy files with reflink
    cp -a --reflink=auto "$BACKUP_SOURCE"/* "$temp_mount/$SUBVOL_NAME"/ || { 
      echo -e "${RED}Failed to copy data${NC}"
      return 1
    }
    echo -e "${GREEN}Data copied successfully${NC}"
  fi
  
  echo -e "${GREEN}Subvolume creation and data copy completed${NC}"
  return 0
}

# Phase 5: Update system configuration
update_system_config() {
  echo -e "${BLUE}Phase 5: Updating system configuration${NC}"
  
  # Update fstab
  echo -e "${YELLOW}Updating fstab for the new subvolume${NC}"
  if ! update_fstab "$TARGET_DEVICE" "$TARGET_MOUNT" "$SUBVOL_NAME"; then
    echo -e "${RED}Failed to update fstab. You may need to update it manually.${NC}"
    # We don't return failure here since we can still proceed
  fi
  
  echo -e "${GREEN}System configuration update completed${NC}"
}

# Phase 6: Cleanup and finalize
cleanup_and_finalize() {
  local temp_mount="$1"
  
  echo -e "${BLUE}Phase 6: Cleanup and finalization${NC}"
  
  # Clean up temporary mount
  echo -e "${YELLOW}Cleaning up temporary mount${NC}"
  if ! cleanup_temp_mount "$temp_mount"; then
    echo -e "${RED}Warning: Failed to clean up temporary mount properly${NC}"
    # Continue despite warning
  fi

  # Remount the target with the new subvolume
  echo -e "${YELLOW}Remounting $TARGET_MOUNT with new subvolume${NC}"
  mount "$TARGET_MOUNT" || { 
    echo -e "${RED}Failed to remount $TARGET_MOUNT. You may need to reboot${NC}"
    return 1
  }
  echo -e "${GREEN}$TARGET_MOUNT remounted successfully with $SUBVOL_NAME subvolume${NC}"
  
  echo -e "${GREEN}Cleanup and finalization completed${NC}"
  return 0
}

# Main function that runs through all phases
main() {
  echo -e "${GREEN}Starting the $SUBVOL_NAME subvolume creation script${NC}"
  echo -e "${BLUE}Configuration:${NC}"
  echo -e "  Backup Drive:     ${YELLOW}$BACKUP_DRIVE${NC}"
  echo -e "  Backup Mount:     ${YELLOW}$BACKUP_MOUNT${NC}"
  echo -e "  Target Device:    ${YELLOW}$TARGET_DEVICE${NC}"
  echo -e "  Target Mount:     ${YELLOW}$TARGET_MOUNT${NC}"
  echo -e "  Subvolume Name:   ${YELLOW}$SUBVOL_NAME${NC}"
  echo -e "  Perform Backup:   ${YELLOW}$DO_BACKUP${NC}"
  echo
  
  # Run through all phases in sequence
  check_prerequisites
  handle_backup
  TEMP_MOUNT=$(prepare_target)
  
  if ! create_subvolume "$TEMP_MOUNT"; then
    echo -e "${RED}Failed to create subvolume. Attempting cleanup...${NC}"
    echo -e "${YELLOW}Attempting cleanup of: $TEMP_MOUNT${NC}"  # Add this debug line
    cleanup_temp_mount "$TEMP_MOUNT"
    exit 1
  fi
  
  update_system_config
  
  if ! cleanup_and_finalize "$TEMP_MOUNT"; then
    echo -e "${RED}Failed to finalize configuration. Manual intervention may be required.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}All done! Your $SUBVOL_NAME subvolume has been created.${NC}"
  echo -e "${YELLOW}You may want to reboot to ensure everything is working correctly.${NC}"
}

#
# Parse command line arguments
#
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      -b|--backup)
        DO_BACKUP=true
        shift
        ;;
      -d|--backup-drive)
        BACKUP_DRIVE="$2"
        shift 2
        ;;
      -m|--backup-mount)
        BACKUP_MOUNT="$2"
        shift 2
        ;;
      -t|--target-device)
        TARGET_DEVICE="$2"
        shift 2
        ;;
      -p|--target-mount)
        TARGET_MOUNT="$2"
        shift 2
        ;;
      -s|--subvol-name)
        SUBVOL_NAME="$2"
        shift 2
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}"
        show_help
        exit 1
        ;;
    esac
  done
}

#
# Script execution starts here
#
parse_arguments "$@"
main