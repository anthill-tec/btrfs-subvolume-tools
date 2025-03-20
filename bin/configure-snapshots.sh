#!/bin/bash
set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
TARGET_MOUNT="/home"
CONFIG_NAME=""
ALLOW_USERS=""
TIMELINE_CREATE="yes"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="6"
TIMELINE_LIMIT_YEARLY="0"
SYNC_ACL="yes"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
ENABLE_PACMAN_HOOKS="yes"
ENABLE_SYSTEMD_TIMERS="yes"
FORCE_UPDATE=false

#
# Utility functions
#

# Show help
show_help() {
  echo -e "${BLUE}Script for configuring snapper for btrfs subvolumes${NC}"
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -h, --help                       Show this help message"
  echo "  -p, --target-mount MOUNTPOINT    Target mount point (default: $TARGET_MOUNT)"
  echo "  -c, --config-name NAME           Configuration name (default: basename of mount point)"
  echo "  -u, --allow-users USERS          Comma-separated list of users allowed to use snapper"
  echo "  -t, --timeline BOOL              Enable timeline snapshots (default: $TIMELINE_CREATE)"
  echo "  -f, --force                      Force update of existing configurations without prompting"
  echo "  --hourly NUMBER                  Number of hourly snapshots to keep (default: $TIMELINE_LIMIT_HOURLY)"
  echo "  --daily NUMBER                   Number of daily snapshots to keep (default: $TIMELINE_LIMIT_DAILY)"
  echo "  --weekly NUMBER                  Number of weekly snapshots to keep (default: $TIMELINE_LIMIT_WEEKLY)"
  echo "  --monthly NUMBER                 Number of monthly snapshots to keep (default: $TIMELINE_LIMIT_MONTHLY)"
  echo "  --yearly NUMBER                  Number of yearly snapshots to keep (default: $TIMELINE_LIMIT_YEARLY)"
  echo "  --no-pacman-hooks                Don't install or configure pacman hooks"
  echo "  --no-timers                      Don't enable systemd timers for snapper"
  echo
  echo "Example:"
  echo "  $0 --target-mount /home --allow-users john,mary"
  echo "  $0 --target-mount /var --config-name var --timeline no"
  echo
}

# Check if running as root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
  fi
}

# Verify snapper is installed
verify_snapper() {
  if ! command -v snapper &> /dev/null; then
    echo -e "${YELLOW}Snapper not found. Attempting to install...${NC}"
    if command -v pacman &> /dev/null; then
      pacman -S --noconfirm snapper || {
        echo -e "${RED}Failed to install snapper. Please install it manually.${NC}"
        exit 1
      }
    elif command -v apt-get &> /dev/null; then
      apt-get update && apt-get install -y snapper || {
        echo -e "${RED}Failed to install snapper. Please install it manually.${NC}"
        exit 1
      }
    elif command -v dnf &> /dev/null; then
      dnf install -y snapper || {
        echo -e "${RED}Failed to install snapper. Please install it manually.${NC}"
        exit 1
      }
    else
      echo -e "${RED}Package manager not detected. Please install snapper manually.${NC}"
      exit 1
    fi
  fi
}

# Verify snap-pac is installed (for Arch Linux)
verify_snap_pac() {
  if [ "$ENABLE_PACMAN_HOOKS" = "yes" ]; then
    if command -v pacman &> /dev/null; then
      if ! pacman -Q snap-pac &> /dev/null; then
        echo -e "${YELLOW}snap-pac not found. Attempting to install...${NC}"
        pacman -S --noconfirm snap-pac || {
          echo -e "${RED}Failed to install snap-pac. Pacman hooks won't be available.${NC}"
          ENABLE_PACMAN_HOOKS="no"
        }
      fi
    else
      echo -e "${YELLOW}Not an Arch-based system. Disabling pacman hooks.${NC}"
      ENABLE_PACMAN_HOOKS="no"
    fi
  fi
}

# Check if target is a btrfs filesystem and verify subvolume exists
check_btrfs_subvolume() {
  local mount_point="$1"
  
  # Check if mount point exists
  if [ ! -d "$mount_point" ]; then
    echo -e "${RED}Error: Mount point $mount_point does not exist${NC}"
    exit 1
  fi
  
  # Check if mount point is mounted
  if ! mountpoint -q "$mount_point"; then
    echo -e "${RED}Error: $mount_point is not mounted${NC}"
    exit 1
  fi
  
  # Check if filesystem is btrfs
  local fs_type=$(findmnt -n -o FSTYPE "$mount_point")
  if [ "$fs_type" != "btrfs" ]; then
    echo -e "${RED}Error: $mount_point is not a btrfs filesystem (found: $fs_type)${NC}"
    exit 1
  fi
  
  # Get device where mount point is located
  local device=$(findmnt -n -o SOURCE "$mount_point")
  
  # Check if the mount is actually a subvolume
  local subvol_path=$(findmnt -n -o OPTIONS "$mount_point" | grep -o 'subvol=[^ ,]*' | sed 's/subvol=//')
  
  if [ -z "$subvol_path" ]; then
    echo -e "${RED}Error: $mount_point is not mounted from a subvolume${NC}"
    exit 1
  fi
  
  # Verify subvolume exists by checking its ID
  # Need to find parent mount to run btrfs commands
  local parent_mount=$(findmnt -n -t btrfs | grep -v "$mount_point" | head -n1 | awk '{print $1}')
  
  if [ -z "$parent_mount" ]; then
    # If no other mount points, try to mount the device temporarily
    parent_mount="/tmp/btrfs_check_$"
    mkdir -p "$parent_mount"
    mount "$device" "$parent_mount" -o subvolid=5 || {
      echo -e "${RED}Error: Could not mount parent volume to verify subvolume${NC}"
      rmdir "$parent_mount"
      exit 1
    }
    local temp_mounted=1
  fi
  
  # Find the subvolume
  local subvol_found=$(btrfs subvolume list "$parent_mount" | grep -F "$subvol_path" | wc -l)
  
  # Unmount temporary mount if we created one
  if [ -n "$temp_mounted" ]; then
    umount "$parent_mount"
    rmdir "$parent_mount"
  fi
  
  if [ "$subvol_found" -eq 0 ]; then
    echo -e "${RED}Error: Subvolume $subvol_path not found on $device${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Verified $mount_point is a valid btrfs subvolume (path: $subvol_path)${NC}"
}

# Configure snapper
configure_snapper() {
  local mount_point="$1"
  local config_name="$2"
  
  # Check if snapper config already exists
  if ! snapper -c "$config_name" list &> /dev/null; then
    echo -e "${YELLOW}Creating snapper configuration for $mount_point${NC}"
    snapper -c "$config_name" create-config "$mount_point" || {
      echo -e "${RED}Failed to create snapper configuration${NC}"
      exit 1
    }
    echo -e "${GREEN}Successfully created snapper configuration ${BLUE}$config_name${NC}"
  else
    echo -e "${YELLOW}Snapper configuration ${BLUE}$config_name${NC} already exists${NC}"
    
    # Ask for confirmation before modifying
    if [ "$FORCE_UPDATE" = false ]; then
      read -p "Do you want to modify the existing configuration? (y/n): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Keeping existing configuration unchanged${NC}"
        return 0
      fi
    else
      echo -e "${YELLOW}Force update enabled, modifying existing configuration${NC}"
    fi
    
    echo -e "${YELLOW}Existing configuration will be updated${NC}"
  fi
  
  # Update snapper configuration
  local config_file="/etc/snapper/configs/$config_name"
  if [ -f "$config_file" ]; then
    echo -e "${YELLOW}Updating snapper configuration...${NC}"
    
    # Create backup of config
    cp "$config_file" "$config_file.bak"
    echo -e "${GREEN}Created backup of configuration at $config_file.bak${NC}"
    
    # Update settings
    if [ -n "$ALLOW_USERS" ]; then
      sed -i "s/^ALLOW_USERS=\".*\"/ALLOW_USERS=\"$ALLOW_USERS\"/" "$config_file"
    fi
    
    sed -i "s/^TIMELINE_CREATE=\".*\"/TIMELINE_CREATE=\"$TIMELINE_CREATE\"/" "$config_file"
    sed -i "s/^TIMELINE_LIMIT_HOURLY=\".*\"/TIMELINE_LIMIT_HOURLY=\"$TIMELINE_LIMIT_HOURLY\"/" "$config_file"
    sed -i "s/^TIMELINE_LIMIT_DAILY=\".*\"/TIMELINE_LIMIT_DAILY=\"$TIMELINE_LIMIT_DAILY\"/" "$config_file"
    sed -i "s/^TIMELINE_LIMIT_WEEKLY=\".*\"/TIMELINE_LIMIT_WEEKLY=\"$TIMELINE_LIMIT_WEEKLY\"/" "$config_file"
    sed -i "s/^TIMELINE_LIMIT_MONTHLY=\".*\"/TIMELINE_LIMIT_MONTHLY=\"$TIMELINE_LIMIT_MONTHLY\"/" "$config_file"
    sed -i "s/^TIMELINE_LIMIT_YEARLY=\".*\"/TIMELINE_LIMIT_YEARLY=\"$TIMELINE_LIMIT_YEARLY\"/" "$config_file"
    sed -i "s/^SYNC_ACL=\".*\"/SYNC_ACL=\"$SYNC_ACL\"/" "$config_file"
    sed -i "s/^BACKGROUND_COMPARISON=\".*\"/BACKGROUND_COMPARISON=\"$BACKGROUND_COMPARISON\"/" "$config_file"
    sed -i "s/^NUMBER_CLEANUP=\".*\"/NUMBER_CLEANUP=\"$NUMBER_CLEANUP\"/" "$config_file"
    
    echo -e "${GREEN}Successfully updated snapper configuration${NC}"
  else
    echo -e "${RED}Error: Configuration file $config_file not found${NC}"
    exit 1
  fi
}

# Enable and start systemd timers
setup_systemd_timers() {
  if [ "$ENABLE_SYSTEMD_TIMERS" = "yes" ]; then
    echo -e "${YELLOW}Setting up systemd timers for snapper...${NC}"
    
    # Enable and start timeline service for creating regular snapshots
    systemctl enable --now snapper-timeline.timer || {
      echo -e "${RED}Failed to enable snapper-timeline.timer${NC}"
      exit 1
    }
    
    # Enable and start cleanup service for removing old snapshots
    systemctl enable --now snapper-cleanup.timer || {
      echo -e "${RED}Failed to enable snapper-cleanup.timer${NC}"
      exit 1
    }
    
    echo -e "${GREEN}Successfully enabled and started snapper systemd timers${NC}"
  else
    echo -e "${YELLOW}Skipping systemd timer setup as requested${NC}"
  fi
}

# Setup Pacman hooks (Arch Linux)
setup_pacman_hooks() {
  if [ "$ENABLE_PACMAN_HOOKS" = "yes" ]; then
    echo -e "${YELLOW}Setting up pacman hooks for snapper...${NC}"
    
    # Verify snap-pac package
    if ! pacman -Q snap-pac &> /dev/null; then
      echo -e "${RED}snap-pac package not installed. Cannot setup pacman hooks.${NC}"
      return 1
    fi
    
    # Verify hooks directory exists
    local hooks_dir="/etc/pacman.d/hooks"
    if [ ! -d "$hooks_dir" ]; then
      mkdir -p "$hooks_dir"
    fi
    
    # Check if hooks are already set up
    if [ -f "$hooks_dir/50-bootbackup.hook" ] || [ -f "/usr/share/libalpm/hooks/50-bootbackup.hook" ]; then
      echo -e "${GREEN}Pacman hooks already set up${NC}"
    else
      echo -e "${YELLOW}Pacman hooks are provided by the snap-pac package${NC}"
    fi
    
    echo -e "${GREEN}Successfully verified pacman hooks setup${NC}"
  else
    echo -e "${YELLOW}Skipping pacman hooks setup as requested${NC}"
  fi
}

# Create snapshot
create_initial_snapshot() {
  local config_name="$1"
  
  echo -e "${YELLOW}Creating initial snapshot...${NC}"
  snapper -c "$config_name" create --description "Initial snapshot" || {
    echo -e "${RED}Failed to create initial snapshot${NC}"
    return 1
  }
  
  echo -e "${GREEN}Successfully created initial snapshot${NC}"
}

#
# Main function that runs through all phases
#
main() {
  # If no config name specified, use basename of mount point
  if [ -z "$CONFIG_NAME" ]; then
    CONFIG_NAME=$(basename "$TARGET_MOUNT")
  fi
  
  echo -e "${GREEN}Starting snapper configuration for subvolume at $TARGET_MOUNT${NC}"
  echo -e "${BLUE}Configuration:${NC}"
  echo -e "  Target Mount:       ${YELLOW}$TARGET_MOUNT${NC}"
  echo -e "  Config Name:        ${YELLOW}$CONFIG_NAME${NC}"
  echo -e "  Allow Users:        ${YELLOW}$ALLOW_USERS${NC}"
  echo -e "  Timeline Snapshots: ${YELLOW}$TIMELINE_CREATE${NC}"
  echo -e "  Snapshot Limits:    ${YELLOW}H:$TIMELINE_LIMIT_HOURLY D:$TIMELINE_LIMIT_DAILY W:$TIMELINE_LIMIT_WEEKLY M:$TIMELINE_LIMIT_MONTHLY Y:$TIMELINE_LIMIT_YEARLY${NC}"
  echo -e "  Pacman Hooks:       ${YELLOW}$ENABLE_PACMAN_HOOKS${NC}"
  echo -e "  Systemd Timers:     ${YELLOW}$ENABLE_SYSTEMD_TIMERS${NC}"
  echo -e "  Force Update:       ${YELLOW}$FORCE_UPDATE${NC}"
  echo
  
  # Run all configuration steps
  check_root
  verify_snapper
  verify_snap_pac
  check_btrfs_subvolume "$TARGET_MOUNT"
  configure_snapper "$TARGET_MOUNT" "$CONFIG_NAME"
  
  # Setup additional components
  if [ "$ENABLE_SYSTEMD_TIMERS" = "yes" ]; then
    setup_systemd_timers
  fi
  
  if [ "$ENABLE_PACMAN_HOOKS" = "yes" ]; then
    setup_pacman_hooks
  fi
  
  # Create first snapshot
  create_initial_snapshot "$CONFIG_NAME"
  
  echo -e "${GREEN}All done! Snapper has been configured for subvolume at $TARGET_MOUNT.${NC}"
  echo -e "${YELLOW}You can now use snapper to manage snapshots with: snapper -c $CONFIG_NAME <command>${NC}"
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
      -p|--target-mount)
        TARGET_MOUNT="$2"
        shift 2
        ;;
      -c|--config-name)
        CONFIG_NAME="$2"
        shift 2
        ;;
      -u|--allow-users)
        ALLOW_USERS="$2"
        shift 2
        ;;
      -t|--timeline)
        TIMELINE_CREATE="$2"
        shift 2
        ;;
      -f|--force)
        FORCE_UPDATE=true
        shift
        ;;
      --hourly)
        TIMELINE_LIMIT_HOURLY="$2"
        shift 2
        ;;
      --daily)
        TIMELINE_LIMIT_DAILY="$2"
        shift 2
        ;;
      --weekly)
        TIMELINE_LIMIT_WEEKLY="$2"
        shift 2
        ;;
      --monthly)
        TIMELINE_LIMIT_MONTHLY="$2"
        shift 2
        ;;
      --yearly)
        TIMELINE_LIMIT_YEARLY="$2"
        shift 2
        ;;
      --no-pacman-hooks)
        ENABLE_PACMAN_HOOKS="no"
        shift
        ;;
      --no-timers)
        ENABLE_SYSTEMD_TIMERS="no"
        shift
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