#!/bin/bash
# Utility functions for managing loop devices in the BTRFS Subvolume Tools test environment

# Global variables for loop devices
TARGET_LOOP=""
BACKUP_LOOP=""

# Ensure loop devices exist on the host system
prepare_host_loop_devices() {
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Preparing host loop devices"
  else
    echo "Preparing host loop devices"
  fi

  # Ensure loop devices exist on the host
  for i in {0..9}; do
    if [ ! -e "/dev/loop$i" ]; then
      if type run_cmd >/dev/null 2>&1; then
        run_cmd 3 "Creating /dev/loop$i on host" "mknod -m 660 \"/dev/loop$i\" b 7 \"$i\" || true"
      else
        echo "Creating /dev/loop$i on host"
        mknod -m 660 "/dev/loop$i" b 7 "$i" || true
      fi
    fi
  done

  # Make sure loop module is loaded on host
  if ! lsmod | grep -q loop; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 3 "Loading loop module on host" "modprobe loop"
    else
      echo "Loading loop module on host"
      modprobe loop
    fi
  fi
}

# Setup loop devices for disk images
setup_test_images_on_host() {
  local target_img="$1"
  local backup_img="$2"
  local output_conf="$3"
  
  # Default values if not provided
  target_img="${target_img:-tests/container/rootfs/images/target-disk.img}"
  backup_img="${backup_img:-tests/container/rootfs/images/backup-disk.img}"
  output_conf="${output_conf:-tests/container/rootfs/loop_devices.conf}"
  
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Setting up host loop devices for container use"
  else
    echo "Setting up host loop devices for container use"
  fi
  
  # Pre-attach the loop devices on the host
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Setting up target loop device" "losetup -f --show \"$target_img\""
    TARGET_LOOP=$(losetup -f --show "$target_img") || {
      if type log_phase >/dev/null 2>&1; then
        log_phase 3 "Failed to set up loop device for target disk"
      else
        echo "Failed to set up loop device for target disk"
      fi
      return 1
    }
    
    run_cmd 3 "Setting up backup loop device" "losetup -f --show \"$backup_img\""
    BACKUP_LOOP=$(losetup -f --show "$backup_img") || {
      if type log_phase >/dev/null 2>&1; then
        log_phase 3 "Failed to set up loop device for backup disk"
      else
        echo "Failed to set up loop device for backup disk"
      fi
      # Clean up the target loop if backup fails
      losetup -d "$TARGET_LOOP" 2>/dev/null || true
      return 1
    }
  else
    echo "Setting up target loop device"
    TARGET_LOOP=$(losetup -f --show "$target_img") || {
      echo "Failed to set up loop device for target disk"
      return 1
    }
    
    echo "Setting up backup loop device"
    BACKUP_LOOP=$(losetup -f --show "$backup_img") || {
      echo "Failed to set up loop device for backup disk"
      # Clean up the target loop if backup fails
      losetup -d "$TARGET_LOOP" 2>/dev/null || true
      return 1
    }
  fi
  
  # Create a file to pass loop device info to the container
  cat > "$output_conf" << EOF
# Loop device configuration for BTRFS Subvolume Tools tests
# Generated: $(date)
TARGET_LOOP=$TARGET_LOOP
BACKUP_LOOP=$BACKUP_LOOP
EOF
  
  # Log success
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Created loop device mappings: $TARGET_LOOP and $BACKUP_LOOP"
  else
    echo "Created loop device mappings: $TARGET_LOOP and $BACKUP_LOOP"
  fi
  
  # Export variables for use in the calling script
  export TARGET_LOOP BACKUP_LOOP
  
  return 0
}

# Create an enhanced container configuration for loop device access
enhance_container_config() {
  local container_name="$1"
  local config_file="/etc/systemd/nspawn/$container_name.nspawn"
  
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Enhancing container configuration for loop device access"
  else
    echo "Enhancing container configuration for loop device access"
  fi
  
  # Create a more robust nspawn configuration
  cat > "$config_file" << EOF
[Exec]
Capability=all

[Files]
BindReadOnly=/dev/loop-control
EOF

  # Add bind mounts for available loop devices
  for i in {0..9}; do
    if [ -e "/dev/loop$i" ]; then
      echo "BindReadOnly=/dev/loop$i" >> "$config_file"
    fi
  done

  # Add specific binds for our attached loop devices
  if [ -n "$TARGET_LOOP" ]; then
    echo "Bind=$TARGET_LOOP" >> "$config_file"
  fi
  
  if [ -n "$BACKUP_LOOP" ]; then
    echo "Bind=$BACKUP_LOOP" >> "$config_file"
  fi

  cat >> "$config_file" << EOF

[DeviceAllow]
Property=block-loop
Value=rw
EOF

  # Report success
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Enhanced container configuration for loop device access"
  else
    echo "Enhanced container configuration for loop device access"
  fi
}

# Clean up loop devices
cleanup_loop_devices() {
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 5 "Cleaning up loop devices"
  else
    echo "Cleaning up loop devices"
  fi
  
  # Detach any loop devices we created
  if [ -n "$TARGET_LOOP" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Detaching target loop device" "losetup -d \"$TARGET_LOOP\" 2>/dev/null || true"
    else
      echo "Detaching target loop device: $TARGET_LOOP"
      losetup -d "$TARGET_LOOP" 2>/dev/null || true
    fi
  fi
  
  if [ -n "$BACKUP_LOOP" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Detaching backup loop device" "losetup -d \"$BACKUP_LOOP\" 2>/dev/null || true"
    else
      echo "Detaching backup loop device: $BACKUP_LOOP"
      losetup -d "$BACKUP_LOOP" 2>/dev/null || true
    fi
  fi
  
  # Clear the variables
  TARGET_LOOP=""
  BACKUP_LOOP=""
}

# Main function to apply all loop device fixes
apply_loop_device_fixes() {
  local container_name="$1"
  
  # Check for required argument
  if [ -z "$container_name" ]; then
    if type log_phase >/dev/null 2>&1; then
      log_phase 3 "Error: Container name not provided to apply_loop_device_fixes"
    else
      echo "Error: Container name not provided to apply_loop_device_fixes"
    fi
    return 1
  fi
  
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Applying all loop device fixes for container: $container_name"
  else
    echo "Applying all loop device fixes for container: $container_name"
  fi
  
  # Apply all fixes in sequence
  prepare_host_loop_devices
  setup_test_images_on_host
  enhance_container_config "$container_name"
  
  # Copy the loop device configuration to the container
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Copying loop device configuration" "cp tests/container/rootfs/loop_devices.conf /var/lib/machines/$container_name/"
  else
    echo "Copying loop device configuration"
    cp tests/container/rootfs/loop_devices.conf "/var/lib/machines/$container_name/"
  fi
  
  # Report success
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "All loop device fixes applied successfully"
  else
    echo "All loop device fixes applied successfully"
  fi
  
  return 0
}
