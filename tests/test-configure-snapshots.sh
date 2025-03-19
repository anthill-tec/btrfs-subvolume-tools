#!/bin/sh
# Test for the configure-snapshots.sh script

# Setup test environment
setup() {
    echo "Setting up test environment..."
    
    # Create test directory
    # Use the global temp directory if available, or create a new one
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        TEST_DIR="$TEST_TEMP_DIR/configure-snapshots-test"
        mkdir -p "$TEST_DIR"
    else
        TEST_DIR=$(mktemp -d /tmp/test-btrfs-XXXXXX)
    fi
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    SUBVOL_NAME="@test"
    CONFIG_NAME="test"
    ALLOW_USERS="testuser"
    
    # Create necessary directories
    mkdir -p "$TARGET_MOUNT"
    
    # Use the disk images found in global setup if available
    if [ -n "$TEST_TARGET_IMAGE" ]; then
        TARGET_IMAGE="$TEST_TARGET_IMAGE"
    else
        # Otherwise, search for it
        TARGET_IMAGE=$(find / -name "target-disk.img" 2>/dev/null | head -n 1)
    fi
    
    # Verify that we found the image
    if [ -z "$TARGET_IMAGE" ]; then
        echo "Error: Could not locate target-disk.img"
        return 1
    fi
    
    echo "Found target image: $TARGET_IMAGE"
    
    # Set up loop devices
    echo "Setting up loop device..."
    
    # Ensure loop8 is not already in use
    losetup | grep -q /dev/loop8 && losetup -d /dev/loop8
    
    # Set up loop device with the image file
    losetup /dev/loop8 "$TARGET_IMAGE" || return 1
    TARGET_DEVICE="/dev/loop8"
    
    echo "  Target device: $TARGET_DEVICE"
    
    # Export variables for the test
    export TEST_DIR TARGET_MOUNT TARGET_DEVICE SUBVOL_NAME CONFIG_NAME ALLOW_USERS
    
    return 0
}

# Run the actual test
run_test() {
    echo "Formatting device with btrfs..."
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    
    echo "Mounting device..."
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    echo "Creating test subvolume..."
    # Create a subvolume first using the btrfs command directly
    btrfs subvolume create "$TARGET_MOUNT/$SUBVOL_NAME" || return 1
    
    echo "Running configure-snapshots script..."
    # Find the script
    SCRIPT_PATH=$(find / -path "*/bin/configure-snapshots.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        echo "Error: Could not locate configure-snapshots.sh"
        return 1
    fi
    
    # Run the script being tested
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT" \
        --config-name "$CONFIG_NAME" \
        --allow-users "$ALLOW_USERS" \
        --force || return 1
    
    echo "Verifying results..."
    # Check if snapper configuration was created
    if [ -f "/etc/snapper/configs/$CONFIG_NAME" ]; then
        echo "✓ Snapper configuration for $CONFIG_NAME was created"
    else
        echo "✗ Snapper configuration for $CONFIG_NAME was not created"
        return 1
    fi
    
    # Check if users were properly set
    if grep -q "ALLOW_USERS=\"$ALLOW_USERS\"" "/etc/snapper/configs/$CONFIG_NAME" 2>/dev/null; then
        echo "✓ User permissions were set correctly"
    else
        echo "✗ User permissions were not set correctly"
        return 1
    fi
    
    # Check if timeline is enabled
    if grep -q "TIMELINE_CREATE=\"yes\"" "/etc/snapper/configs/$CONFIG_NAME" 2>/dev/null; then
        echo "✓ Timeline creation is enabled"
    else
        echo "✗ Timeline creation was not configured properly"
        return 1
    fi
    
    # Check if we can create a snapshot
    if snapper -c "$CONFIG_NAME" create -d "Test snapshot" >/dev/null 2>&1; then
        echo "✓ Successfully created a test snapshot"
        
        # Check if we can list snapshots
        if snapper -c "$CONFIG_NAME" list | grep -q "Test snapshot"; then
            echo "✓ Successfully listed snapshots"
        else
            echo "✗ Could not list snapshots"
            return 1
        fi
    else
        echo "✗ Failed to create a test snapshot"
        return 1
    fi
    
    return 0
}

# Clean up after test
teardown() {
    echo "Cleaning up test environment..."
    
    # Remove snapper config
    if [ -f "/etc/snapper/configs/$CONFIG_NAME" ]; then
        echo "Removing test snapper configuration..."
        snapper -c "$CONFIG_NAME" delete-config 2>/dev/null || true
    fi
    
    # Unmount before detaching loop device
    umount "$TARGET_MOUNT" 2>/dev/null || true
    
    # Detach loop device
    losetup -d "$TARGET_DEVICE" 2>/dev/null || true
    
    # Remove the test directory (unless it's part of the global temp dir)
    if [ -z "$TEST_TEMP_DIR" ] || [ ! -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
    
    return 0
}