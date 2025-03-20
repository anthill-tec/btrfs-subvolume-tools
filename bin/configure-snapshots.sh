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
NON_INTERACTIVE=false

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
  echo "  -n, --non-interactive            Run without prompting for user input and continue on non-critical errors"
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

# Function to validate users
validate_users() {
  local user_list="$1"
  local invalid_users=""
  
  # If no users specified, return success
  if [ -z "$user_list" ]; then
    return 0
  fi
  
  # Check each user
  for username in $(echo "$user_list" | tr ',' ' '); do
    if ! id "$username" &>/dev/null; then
      if [ -z "$invalid_users" ]; then
        invalid_users="$username"
      else
        invalid_users="$invalid_users, $username"
      fi
    fi
  done
  
  # Report invalid users
  if [ -n "$invalid_users" ]; then
    echo -e "${RED}Error: The following users do not exist: $invalid_users${NC}"
    if [ "$NON_INTERACTIVE" = true ]; then
      echo -e "${YELLOW}Non-interactive mode: Continuing despite invalid users${NC}"
      return 0
    else
      return 1
    fi
  fi
  
  return 0
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
    echo -e "${YELLOW}Warning: $mount_point is not mounted. Attempting to mount it...${NC}"
    
    # Try to determine the subvolume name from the path
    local subvol_name=$(basename "$mount_point")
    
    # Try to find the device
    local device="$TARGET_DEVICE"
    if [ -z "$device" ]; then
      # If TARGET_DEVICE not defined, try to find from loop_devices.conf
      if [ -f "/loop_devices.conf" ]; then
        source /loop_devices.conf
        device="$TARGET_LOOP"
      fi
      
      # If still empty, try the default test device
      if [ -z "$device" ]; then
        device="/dev/loop8"
      fi
    fi
    
    echo -e "${YELLOW}Attempting to mount $device to $mount_point with subvolume=$subvol_name${NC}"
    mkdir -p "$mount_point" 2>/dev/null
    mount -t btrfs -o subvol="$subvol_name" "$device" "$mount_point" || {
      echo -e "${RED}Error: Could not mount $mount_point${NC}"
      exit 1
    }
    echo -e "${GREEN}Successfully mounted $device to $mount_point${NC}"
  fi
  
  # Continue with the original checks...
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
      if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${YELLOW}Non-interactive mode: Automatically updating existing configuration${NC}"
        update_decision="y"
      else
        read -p "Do you want to modify the existing configuration? (Y/n): " -n 1 -r update_decision
        echo
        # Default to "y" if user just presses Enter
        update_decision=${update_decision:-y}
        
        if [[ ! $update_decision =~ ^[Yy]$ ]]; then
          echo -e "${YELLOW}Keeping existing configuration unchanged${NC}"
          return 0
        fi
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
  
  # Check if we're in non-interactive mode
  if [ "$NON_INTERACTIVE" = true ]; then
    # In non-interactive mode, don't fail if initial snapshot creation fails
    snapper -c "$config_name" create --description "Initial snapshot" || {
      echo -e "${RED}Failed to create initial snapshot${NC}"
      echo -e "${YELLOW}Continuing in non-interactive mode...${NC}"
      return 0  # Return success despite the error
    }
  else
    # In interactive mode, fail if initial snapshot creation fails
    snapper -c "$config_name" create --description "Initial snapshot" || {
      echo -e "${RED}Failed to create initial snapshot${NC}"
      return 1
    }
  fi
  
  echo -e "${GREEN}Successfully created initial snapshot${NC}"
  return 0
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
  echo -e "  Non-Interactive:    ${YELLOW}$NON_INTERACTIVE${NC}"
  echo
  
  # Run all configuration steps
  check_root
  verify_snapper
  verify_snap_pac
  
  # Validate users if specified
  if [ -n "$ALLOW_USERS" ]; then
    if ! validate_users "$ALLOW_USERS"; then
      echo -e "${RED}User validation failed. Please specify valid users or use --non-interactive.${NC}"
      exit 1
    fi
  fi
  
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
      -n|--non-interactive)
        NON_INTERACTIVE=true
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