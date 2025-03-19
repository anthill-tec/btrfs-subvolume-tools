#!/bin/bash
# Test for the create-subvolume.sh script
# Using test_* functions approach and leveraging the global hooks

# Global test variables
TEST_DIR=""
TARGET_MOUNT=""
BACKUP_MOUNT=""
TARGET_DEVICE=""
BACKUP_DEVICE=""
SCRIPT_PATH=""

# Setup test environment 
setup() {
    echo "Setting up test environment..."
    
    # Use the global temp directory provided by setup_all.sh
    TEST_DIR="$TEST_TEMP_DIR/create-subvolume-test"
    mkdir -p "$TEST_DIR"
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    BACKUP_MOUNT="$TEST_DIR/mnt-backup"
    
    # Create necessary directories
    mkdir -p "$TARGET_MOUNT" "$BACKUP_MOUNT"
    
    # Use the disk images and loop devices already set up by setup_all.sh
    # The global hook should make these available as environment variables
    TARGET_DEVICE="/dev/loop8"  # Using the standard loop device from setup_all.sh
    BACKUP_DEVICE="/dev/loop9"  # Using the standard loop device from setup_all.sh
    
    echo "Target device: $TARGET_DEVICE"
    echo "Backup device: $BACKUP_DEVICE"
    
    # Find the script path
    SCRIPT_PATH=$(find / -path "*/bin/create-subvolume.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        echo "Error: Could not locate create-subvolume.sh"
        return 1
    fi
    
    echo "Found script: $SCRIPT_PATH"
    
    # Format both devices with btrfs
    echo "Formatting devices with btrfs..."
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    mkfs.btrfs -f "$BACKUP_DEVICE" || return 1
    
    return 0
}

# Common function to prepare test data
prepare_test_data() {
    echo "Creating test data..."
    # Mount target device to create test data
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    # Create some test files
    mkdir -p "$TARGET_MOUNT/testdir"
    echo "This is a test file" > "$TARGET_MOUNT/testfile.txt"
    echo "Another test file" > "$TARGET_MOUNT/testdir/nested.txt"
    dd if=/dev/urandom of="$TARGET_MOUNT/testdir/random.bin" bs=1M count=2 status=none
    
    # Unmount before running the script
    umount "$TARGET_MOUNT"
    return 0
}

# Common function to verify subvolume creation and data integrity
verify_subvolume() {
    local subvol_name="$1"
    
    echo "Verifying results..."
    # Mount target to verify
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    # Check if the subvolume was created
    if ! btrfs subvolume list "$TARGET_MOUNT" | grep -q "$subvol_name"; then
        echo "✗ Subvolume $subvol_name was not created"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Subvolume $subvol_name was created successfully"
    
    # Check if data was properly copied
    if [ ! -f "$TARGET_MOUNT/$subvol_name/testfile.txt" ] || 
       [ ! -f "$TARGET_MOUNT/$subvol_name/testdir/nested.txt" ] || 
       [ ! -f "$TARGET_MOUNT/$subvol_name/testdir/random.bin" ]; then
        echo "✗ Not all data files were copied to the subvolume"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Data files were copied to the subvolume"
    
    # Verify file contents
    if ! diff "$TARGET_MOUNT/testfile.txt" "$TARGET_MOUNT/$subvol_name/testfile.txt" >/dev/null; then
        echo "✗ File content verification failed"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ File content verification passed"
    
    # Clean up mount
    umount "$TARGET_MOUNT"
    
    return 0
}

# Test with default configuration (only backup flag provided)
test_with_defaults_and_backup() {
    echo "Running test: Default configuration with backup flag"
    
    # Prepare test data
    prepare_test_data || return 1
    
    # Run the script with minimal arguments (only backup flag)
    "$SCRIPT_PATH" \
        --target-device "$TARGET_DEVICE" \
        --target-mount "$TARGET_MOUNT" \
        --backup-drive "$BACKUP_DEVICE" \
        --backup-mount "$BACKUP_MOUNT" \
        --backup || return 1
    
    # Verify results
    verify_subvolume "@home" || return 1
    
    # Special verification for this test case: verify backup was created
    if ! mount "$BACKUP_DEVICE" "$BACKUP_MOUNT"; then
        echo "✗ Failed to mount backup device"
        return 1
    fi
    
    # Check if backup files exist
    BACKUP_DIR=$(find "$BACKUP_MOUNT" -type d -name "backup_*" | head -n 1)
    if [ -z "$BACKUP_DIR" ]; then
        echo "✗ Backup directory was not created"
        umount "$BACKUP_MOUNT"
        return 1
    fi
    
    if [ ! -f "$BACKUP_DIR/testfile.txt" ]; then
        echo "✗ Backup data verification failed - missing files"
        umount "$BACKUP_MOUNT"
        return 1
    fi
    
    echo "✓ Backup data verification passed"
    umount "$BACKUP_MOUNT"
    
    return 0
}

# Test with custom subvolume name
test_with_custom_subvolume() {
    echo "Running test: Custom subvolume name"
    
    # Reset the filesystem and prepare new test data
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    prepare_test_data || return 1
    
    # Custom subvolume name for this test
    local custom_subvol="@custom_home"
    
    # Run the script with custom subvolume name
    "$SCRIPT_PATH" \
        --target-device "$TARGET_DEVICE" \
        --target-mount "$TARGET_MOUNT" \
        --backup-drive "$BACKUP_DEVICE" \
        --backup-mount "$BACKUP_MOUNT" \
        --subvol-name "$custom_subvol" \
        --backup || return 1
    
    # Verify results with the custom subvolume name
    verify_subvolume "$custom_subvol" || return 1
    
    return 0
}

# Test reusing existing backup (no --backup flag)
test_with_existing_backup() {
    echo "Running test: Using existing backup data"
    
    # Reset the filesystem
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    
    # Prepare test data directly on the backup device
    echo "Creating test data on backup device..."
    mount "$BACKUP_DEVICE" "$BACKUP_MOUNT" || return 1
    
    mkdir -p "$BACKUP_MOUNT/testdir"
    echo "This is a backup file" > "$BACKUP_MOUNT/testfile.txt"
    echo "Another backup file" > "$BACKUP_MOUNT/testdir/nested.txt"
    dd if=/dev/urandom of="$BACKUP_MOUNT/testdir/random.bin" bs=1M count=2 status=none
    
    umount "$BACKUP_MOUNT"
    
    # Run the script without the backup flag (use existing backup)
    "$SCRIPT_PATH" \
        --target-device "$TARGET_DEVICE" \
        --target-mount "$TARGET_MOUNT" \
        --backup-drive "$BACKUP_DEVICE" \
        --backup-mount "$BACKUP_MOUNT" \
        --subvol-name "@reused_backup" || return 1
    
    # Mount and verify data was copied from backup
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    if [ ! -f "$TARGET_MOUNT/@reused_backup/testfile.txt" ]; then
        echo "✗ Data from backup was not properly copied"
        umount "$TARGET_MOUNT"
        return 1
    fi
    
    # Verify content
    if ! grep -q "This is a backup file" "$TARGET_MOUNT/@reused_backup/testfile.txt"; then
        echo "✗ File content verification failed"
        umount "$TARGET_MOUNT"
        return 1
    fi
    
    echo "✓ Data from backup was properly copied and verified"
    umount "$TARGET_MOUNT"
    
    return 0
}

# Test with /var mount point for system subvolume
test_system_var_subvolume() {
    echo "Running test: Creating @var system subvolume"
    
    # Reset the filesystem and prepare new test data
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    
    # Create a custom system directory structure for /var
    local var_target="$TEST_DIR/mnt-var"
    mkdir -p "$var_target"
    
    # Mount and prepare data
    mount "$TARGET_DEVICE" "$var_target" || return 1
    
    # Create minimal /var structure
    mkdir -p "$var_target/cache"
    mkdir -p "$var_target/log"
    mkdir -p "$var_target/lib"
    echo "var test file" > "$var_target/test.txt"
    
    umount "$var_target"
    
    # Run the script to create @var subvolume
    "$SCRIPT_PATH" \
        --target-device "$TARGET_DEVICE" \
        --target-mount "$var_target" \
        --backup-drive "$BACKUP_DEVICE" \
        --backup-mount "$BACKUP_MOUNT" \
        --subvol-name "@var" \
        --backup || return 1
    
    # Mount and verify structure
    mount "$TARGET_DEVICE" "$var_target" || return 1
    
    if [ ! -d "$var_target/@var/cache" ] || [ ! -d "$var_target/@var/log" ] || [ ! -d "$var_target/@var/lib" ]; then
        echo "✗ System directories were not properly copied to @var subvolume"
        umount "$var_target"
        return 1
    fi
    
    if [ ! -f "$var_target/@var/test.txt" ] || ! grep -q "var test file" "$var_target/@var/test.txt"; then
        echo "✗ Test file was not properly copied to @var subvolume"
        umount "$var_target"
        return 1
    fi
    
    echo "✓ @var subvolume structure and content verified"
    umount "$var_target"
    
    return 0
}

# Clean up after test - simplified because global teardown handles most cleanup
teardown() {
    echo "Cleaning up test environment..."
    
    # Unmount any filesystems we might have mounted
    mount | grep "$TEST_DIR" | awk '{print $3}' | while read mount_point; do
        umount "$mount_point" 2>/dev/null || true
    done
    
    # Remove any test-specific directories
    rm -rf "$TEST_DIR" 2>/dev/null || true
    
    # Note: The global teardown_all handles loop device cleanup
    return 0
}