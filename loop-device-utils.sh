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
  
  # Ensure btrfs-control device exists
  if [ ! -e "/dev/btrfs-control" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 3 "Creating /dev/btrfs-control on host" "mknod -m 660 /dev/btrfs-control c 10 234 || true"
    else
      echo "Creating /dev/btrfs-control on host"
      mknod -m 660 /dev/btrfs-control c 10 234 || true
    fi
  fi
  
  # Fix permissions on btrfs-control to ensure it's accessible
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Setting permissions on btrfs-control" "chmod 666 /dev/btrfs-control || true"
  else
    echo "Setting permissions on btrfs-control"
    chmod 666 /dev/btrfs-control || true
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
  
  # Fix permissions on the loop devices to make them usable in the container
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Setting permissions on target loop device" "chmod 666 \"$TARGET_LOOP\""
    run_cmd 3 "Setting permissions on backup loop device" "chmod 666 \"$BACKUP_LOOP\""
  else
    echo "Setting permissions on target loop device"
    chmod 666 "$TARGET_LOOP"
    echo "Setting permissions on backup loop device"
    chmod 666 "$BACKUP_LOOP"
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

# Apply loop device fixes for container
apply_loop_device_fixes() {
  local container_name="$1"
  
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Setting up loop devices for container use"
  else
    echo "Setting up loop devices for container use"
  fi
  
  # 1. Make sure loop module is loaded
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Ensuring loop module is loaded" "modprobe loop"
  else
    echo "Ensuring loop module is loaded"
    modprobe loop
  fi
  
  # 2. Create loop device nodes directly on the host if they don't exist
  for i in {0..10}; do
    if [ ! -e "/dev/loop$i" ]; then
      if type run_cmd >/dev/null 2>&1; then
        run_cmd 3 "Creating loop device node /dev/loop$i" "mknod -m 660 /dev/loop$i b 7 $i || true"
      else
        echo "Creating loop device node /dev/loop$i"
        mknod -m 660 /dev/loop$i b 7 $i || true
      fi
    fi
  done
  
  # 3. Set permissions to make loop devices accessible
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Setting permissions on loop devices" "chmod 666 /dev/loop* || true"
  else
    echo "Setting permissions on loop devices"
    chmod 666 /dev/loop* || true
  fi
  
  # 4. Create images directory in container if needed
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Ensuring image directory exists" "mkdir -p /var/lib/machines/$container_name/images"
  else
    echo "Ensuring image directory exists"
    mkdir -p "/var/lib/machines/$container_name/images"
  fi
  
  # 5. Create loop devices inside the container 
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Creating loop devices in container" "mkdir -p /var/lib/machines/$container_name/dev"
  else
    echo "Creating loop devices in container"
    mkdir -p "/var/lib/machines/$container_name/dev"
  fi
  
  for i in {0..10}; do
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 3 "Creating loop$i in container" "mknod -m 666 /var/lib/machines/$container_name/dev/loop$i b 7 $i || true"
    else
      echo "Creating loop$i in container"
      mknod -m 666 "/var/lib/machines/$container_name/dev/loop$i" b 7 $i || true
    fi
  done
  
  # 6. Explicitly set up loop devices with image files
  # Detach any existing associations for these loop devices
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Detaching loop8 if used" "losetup -d /dev/loop8 2>/dev/null || true"
    run_cmd 3 "Detaching loop9 if used" "losetup -d /dev/loop9 2>/dev/null || true"
    
    # Explicitly associate loop8 and loop9 with our image files
    run_cmd 3 "Setting up target loop device" "losetup /dev/loop8 /var/lib/machines/$container_name/images/target-disk.img"
    run_cmd 3 "Setting up backup loop device" "losetup /dev/loop9 /var/lib/machines/$container_name/images/backup-disk.img"
    
    # Ensure very broad permissions
    run_cmd 3 "Setting permissions" "chmod 666 /dev/loop8 /dev/loop9"
  else
    # Non-logging version
    losetup -d /dev/loop8 2>/dev/null || true
    losetup -d /dev/loop9 2>/dev/null || true
    losetup /dev/loop8 /var/lib/machines/$container_name/images/target-disk.img
    losetup /dev/loop9 /var/lib/machines/$container_name/images/backup-disk.img
    chmod 666 /dev/loop8 /dev/loop9
  fi
  
  # 7. Create a configuration file to help container scripts find loop devices
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Creating loop_devices.conf in container" "cat > /var/lib/machines/$container_name/loop_devices.conf << EOF
# Loop device configuration for BTRFS Subvolume Tools tests
# Generated: $(date)
TARGET_LOOP=/dev/loop8
BACKUP_LOOP=/dev/loop9
EOF"
  else
    echo "Creating loop_devices.conf in container"
    cat > "/var/lib/machines/$container_name/loop_devices.conf" << EOF
# Loop device configuration for BTRFS Subvolume Tools tests
# Generated: $(date)
TARGET_LOOP=/dev/loop8
BACKUP_LOOP=/dev/loop9
EOF
  fi
  
  # 8. Set up a comprehensive nspawn configuration with proper permissions
  if type run_cmd >/dev/null 2>&1; then
    run_cmd 3 "Creating nspawn configuration" "cat > '/etc/systemd/nspawn/$container_name.nspawn' << EOF
[Exec]
# Maintain existing capabilities
Capability=CAP_SYS_ADMIN CAP_MKNOD CAP_SYS_MODULE
# Disable user namespacing to avoid permission issues
PrivateUsers=no

[Files]
# Bind necessary loop and control devices
BindReadOnly=/dev/loop-control
Bind=/dev/loop0
Bind=/dev/loop1
Bind=/dev/loop2
Bind=/dev/loop3
Bind=/dev/loop4
Bind=/dev/loop5
Bind=/dev/loop6
Bind=/dev/loop7
Bind=/dev/loop8
Bind=/dev/loop9
Bind=/dev/loop10
Bind=/dev/btrfs-control

[DeviceAllow]
# Allow all block devices with full permissions
Property=block
Value=rwm

# Allow all character devices needed for btrfs
Property=char-misc
Value=rwm
EOF"
  else
    echo "Creating nspawn configuration"
    cat > "/etc/systemd/nspawn/$container_name.nspawn" << EOF
[Exec]
# Maintain existing capabilities
Capability=CAP_SYS_ADMIN CAP_MKNOD CAP_SYS_MODULE
# Disable user namespacing to avoid permission issues
PrivateUsers=no

[Files]
# Bind necessary loop and control devices
BindReadOnly=/dev/loop-control
Bind=/dev/loop0
Bind=/dev/loop1
Bind=/dev/loop2
Bind=/dev/loop3
Bind=/dev/loop4
Bind=/dev/loop5
Bind=/dev/loop6
Bind=/dev/loop7
Bind=/dev/loop8
Bind=/dev/loop9
Bind=/dev/loop10
Bind=/dev/btrfs-control

[DeviceAllow]
# Allow all block devices with full permissions
Property=block
Value=rwm

# Allow all character devices needed for btrfs
Property=char-misc
Value=rwm
EOF
  fi
  
  if type log_phase >/dev/null 2>&1; then
    log_phase 3 "Loop device setup complete"
  else
    echo "Loop device setup complete"
  fi
}

# Clean up loop devices and restore system state
cleanup_loop_devices() {
  local container_name="$1"
  
  # Log this operation if logging functions are available
  if type log_phase >/dev/null 2>&1; then
    log_phase 5 "Cleaning up loop devices and restoring system state"
  else
    echo "Cleaning up loop devices and restoring system state"
  fi
  
  # Detach any loop devices we created
  if [ -n "$TARGET_LOOP" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Detaching target loop device" "losetup -d \"$TARGET_LOOP\" 2>/dev/null || true"
    else
      echo "Detaching target loop device: $TARGET_LOOP"
      losetup -d "$TARGET_LOOP" 2>/dev/null || true
    fi
    
    # Restore original permissions if loop device still exists
    if [ -e "$TARGET_LOOP" ]; then
      if type run_cmd >/dev/null 2>&1; then
        run_cmd 5 "Restoring permissions on $TARGET_LOOP" "chmod 660 \"$TARGET_LOOP\" 2>/dev/null || true"
      else
        echo "Restoring permissions on $TARGET_LOOP"
        chmod 660 "$TARGET_LOOP" 2>/dev/null || true
      fi
    fi
  fi
  
  if [ -n "$BACKUP_LOOP" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Detaching backup loop device" "losetup -d \"$BACKUP_LOOP\" 2>/dev/null || true"
    else
      echo "Detaching backup loop device: $BACKUP_LOOP"
      losetup -d "$BACKUP_LOOP" 2>/dev/null || true
    fi
    
    # Restore original permissions if loop device still exists
    if [ -e "$BACKUP_LOOP" ]; then
      if type run_cmd >/dev/null 2>&1; then
        run_cmd 5 "Restoring permissions on $BACKUP_LOOP" "chmod 660 \"$BACKUP_LOOP\" 2>/dev/null || true"
      else
        echo "Restoring permissions on $BACKUP_LOOP"
        chmod 660 "$BACKUP_LOOP" 2>/dev/null || true
      fi
    fi
  fi
  
  # Restore btrfs-control permissions if it exists and we modified it
  if [ -e "/dev/btrfs-control" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Restoring permissions on btrfs-control" "chmod 660 /dev/btrfs-control 2>/dev/null || true"
    else
      echo "Restoring permissions on btrfs-control"
      chmod 660 /dev/btrfs-control 2>/dev/null || true
    fi
  fi
  
  # Remove the container configuration file if it exists
  if [ -n "$container_name" ] && [ -f "/etc/systemd/nspawn/$container_name.nspawn" ]; then
    if type run_cmd >/dev/null 2>&1; then
      run_cmd 5 "Removing container configuration" "rm -f \"/etc/systemd/nspawn/$container_name.nspawn\" 2>/dev/null || true"
    else
      echo "Removing container configuration"
      rm -f "/etc/systemd/nspawn/$container_name.nspawn" 2>/dev/null || true
    fi
  fi
  
  # Clear the variables
  TARGET_LOOP=""
  BACKUP_LOOP=""
  
  # Log completion
  if type log_phase >/dev/null 2>&1; then
    log_phase 5 "System state restoration complete"
  else
    echo "System state restoration complete"
  fi
}