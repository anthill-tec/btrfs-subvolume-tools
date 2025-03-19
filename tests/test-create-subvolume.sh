#!/bin/sh
# Test for the create-subvolume.sh script

# Setup test environment 
setup() {
    echo "Setting up test environment..."
    
    # Create test directory structure
    # Use the global temp directory if available, or create a new one
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        TEST_DIR="$TEST_TEMP_DIR/create-subvolume-test"
        mkdir -p "$TEST_DIR"
    else
        TEST_DIR=$(mktemp -d /tmp/test-btrfs-XXXXXX)
    fi
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    BACKUP_MOUNT="$TEST_DIR/mnt-backup"
    SUBVOL_NAME="@test"
    
    # Create necessary directories
    mkdir -p "$TARGET_MOUNT" "$BACKUP_MOUNT"
    
    # Use the disk images found in global setup if available
    if [ -n "$TEST_TARGET_IMAGE" ] && [ -n "$TEST_BACKUP_IMAGE" ]; then
        TARGET_IMAGE="$TEST_TARGET_IMAGE"
        BACKUP_IMAGE="$TEST_BACKUP_IMAGE"
    else
        # Otherwise, search for them
        TARGET_IMAGE=$(find / -name "target-disk.img" 2>/dev/null | head -n 1)
        BACKUP_IMAGE=$(find / -name "backup-disk.img" 2>/dev/null | head -n 1)
    fi
    
    # Verify that we found the images
    if [ -z "$TARGET_IMAGE" ]; then
        echo "Error: Could not locate target-disk.img"
        return 1
    fi
    
    if [ -z "$BACKUP_IMAGE" ]; then
        echo "Error: Could not locate backup-disk.img"
        return 1
    fi
    
    echo "Found target image: $TARGET_IMAGE"
    echo "Found backup image: $BACKUP_IMAGE"
    
    # Set up loop devices
    echo "Setting up loop devices..."
    
    # Check if loop devices are already in use
    losetup | grep -q /dev/loop8 && losetup -d /dev/loop8
    losetup | grep -q /dev/loop9 && losetup -d /dev/loop9
    
    # Set up loop devices with the image files
    losetup /dev/loop8 "$TARGET_IMAGE" || return 1
    losetup /dev/loop9 "$BACKUP_IMAGE" || return 1
    TARGET_DEVICE="/dev/loop8"
    BACKUP_DEVICE="/dev/loop9"
    
    echo "  Target device: $TARGET_DEVICE"
    echo "  Backup device: $BACKUP_DEVICE"
    
    # Export these variables for the test
    export TEST_DIR TARGET_MOUNT BACKUP_MOUNT TARGET_DEVICE BACKUP_DEVICE SUBVOL_NAME
    
    return 0
}

# Run the actual test
run_test() {
    echo "Formatting devices with btrfs..."
    # Format both devices with btrfs
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    mkfs.btrfs -f "$BACKUP_DEVICE" || return 1
    
    echo "Creating test data..."
    # Mount target device to create test data
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    # Create some test files
    mkdir -p "$TARGET_MOUNT/testdir"
    echo "This is a test file" > "$TARGET_MOUNT/testfile.txt"
    echo "Another test file" > "$TARGET_MOUNT/testdir/nested.txt"
    dd if=/dev/urandom of="$TARGET_MOUNT/testdir/random.bin" bs=1M count=10 status=none
    
    # Unmount before running the script
    umount "$TARGET_MOUNT"
    
    echo "Running create-subvolume script..."
    # Run the script being tested
    SCRIPT_PATH=$(find / -path "*/bin/create-subvolume.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        echo "Error: Could not locate create-subvolume.sh"
        return 1
    fi
    
    "$SCRIPT_PATH" \
        --target-device "$TARGET_DEVICE" \
        --target-mount "$TARGET_MOUNT" \
        --backup-drive "$BACKUP_DEVICE" \
        --backup-mount "$BACKUP_MOUNT" \
        --subvol-name "$SUBVOL_NAME" \
        --backup || return 1
    
    echo "Verifying results..."
    # Check if the subvolume was created
    if btrfs subvolume list "$TARGET_MOUNT" | grep -q "$SUBVOL_NAME"; then
        echo "✓ Subvolume $SUBVOL_NAME was created successfully"
    else
        echo "✗ Subvolume $SUBVOL_NAME was not created"
        return 1
    fi
    
    # Check if data was properly copied
    if [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testfile.txt" ] && \
       [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testdir/nested.txt" ] && \
       [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testdir/random.bin" ]; then
        echo "✓ Data files were copied to the subvolume"
        
        # Verify file contents
        if diff "$TARGET_MOUNT/testfile.txt" "$TARGET_MOUNT/$SUBVOL_NAME/testfile.txt" >/dev/null; then
            echo "✓ File content verification passed"
        else
            echo "✗ File content verification failed"
            return 1
        fi
    else
        echo "✗ Not all data files were copied to the subvolume"
        return 1
    fi
    
    return 0
}

# Clean up after test
teardown() {
    echo "Cleaning up test environment..."
    
    # Make sure we unmount before detaching loop devices
    umount "$TARGET_MOUNT" 2>/dev/null || true
    umount "$BACKUP_MOUNT" 2>/dev/null || true
    
    # Detach loop devices
    losetup -d "$TARGET_DEVICE" 2>/dev/null || true
    losetup -d "$BACKUP_DEVICE" 2>/dev/null || true
    
    # Remove the test directory (unless it's part of the global temp dir)
    if [ -z "$TEST_TEMP_DIR" ] || [ ! -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
    
    return 0
}