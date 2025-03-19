#!/bin/bash
# Test for the configure-snapshots.sh script
# Updated to use test_* functions approach and leverage global hooks

# Global test variables
TEST_DIR=""
TARGET_MOUNT=""
TARGET_DEVICE=""
SCRIPT_PATH=""

# Setup test environment
setup() {
    echo "Setting up test environment..."
    
    # Use the global temp directory provided by setup_all.sh
    TEST_DIR="$TEST_TEMP_DIR/configure-snapshots-test"
    mkdir -p "$TEST_DIR"
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    mkdir -p "$TARGET_MOUNT"
    
    # Use the loop device already set up by setup_all.sh
    TARGET_DEVICE="/dev/loop8"  # Using the standard loop device from setup_all.sh
    
    echo "Target device: $TARGET_DEVICE"
    
    # Find the script path
    SCRIPT_PATH=$(find / -path "*/bin/configure-snapshots.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        echo "Error: Could not locate configure-snapshots.sh"
        return 1
    fi
    
    echo "Found script: $SCRIPT_PATH"
    
    # Format device with btrfs
    echo "Formatting device with btrfs..."
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    
    return 0
}

# Create a btrfs subvolume for testing
prepare_subvolume() {
    local subvol_name="$1"
    
    echo "Creating test subvolume..."
    
    # Mount target device
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    # Create the subvolume
    btrfs subvolume create "$TARGET_MOUNT/$subvol_name" || {
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Create some test files and directories in the subvolume
    mkdir -p "$TARGET_MOUNT/$subvol_name/test-dir"
    echo "Test file in subvolume" > "$TARGET_MOUNT/$subvol_name/test-file.txt"
    
    echo "✓ Test subvolume $subvol_name created successfully"
    return 0
}

# Clean up after test - simplified because global teardown handles most cleanup
teardown() {
    echo "Cleaning up test environment..."
    
    # Try to remove any snapper configurations we created
    for config in test home var custom; do
        snapper -c "$config" delete-config 2>/dev/null || true
    done
    
    # Unmount any filesystems we might have mounted
    mount | grep "$TEST_DIR" | awk '{print $3}' | while read mount_point; do
        umount "$mount_point" 2>/dev/null || true
    done
    
    # Remove any test-specific directories
    rm -rf "$TEST_DIR" 2>/dev/null || true
    
    # Note: The global teardown_all handles loop device cleanup
    return 0
}

# Test with default configuration
test_default_config() {
    echo "Running test: Default configuration"
    
    # Create a test subvolume
    prepare_subvolume "@home" || return 1
    
    # Run the script with default configuration
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT/@home" \
        --config-name "test" \
        --force || {
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Verify snapper configuration was created
    if [ ! -f "/etc/snapper/configs/test" ]; then
        echo "✗ Snapper configuration for 'test' was not created"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Snapper configuration was created successfully"
    
    # Check timeline settings (default is "yes")
    if ! grep -q "TIMELINE_CREATE=\"yes\"" "/etc/snapper/configs/test"; then
        echo "✗ Timeline creation not properly configured"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Timeline settings properly configured"
    
    # Test creating a snapshot
    if ! snapper -c "test" create -d "Test snapshot"; then
        echo "✗ Failed to create a test snapshot"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Successfully created a test snapshot"
    
    # Verify snapshot exists
    if ! snapper -c "test" list | grep -q "Test snapshot"; then
        echo "✗ Could not find created snapshot"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Successfully verified snapshot creation"
    
    # Clean up
    umount "$TARGET_MOUNT"
    return 0
}

# Test with user permissions
test_with_user_permissions() {
    echo "Running test: User permissions configuration"
    
    # Reset filesystem and prepare new subvolume
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    prepare_subvolume "@home" || return 1
    
    # Test users to allow
    local test_users="testuser1,testuser2"
    
    # Run the script with user permissions
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT/@home" \
        --config-name "home" \
        --allow-users "$test_users" \
        --force || {
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Verify snapper configuration was created
    if [ ! -f "/etc/snapper/configs/home" ]; then
        echo "✗ Snapper configuration for 'home' was not created"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Snapper configuration was created successfully"
    
    # Check user permissions
    if ! grep -q "ALLOW_USERS=\"$test_users\"" "/etc/snapper/configs/home"; then
        echo "✗ User permissions not properly configured"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ User permissions properly configured"
    
    # Clean up
    umount "$TARGET_MOUNT"
    return 0
}

# Test with timeline disabled
test_with_timeline_disabled() {
    echo "Running test: Timeline disabled configuration"
    
    # Reset filesystem and prepare new subvolume
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    prepare_subvolume "@var" || return 1
    
    # Run the script with timeline disabled
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT/@var" \
        --config-name "var" \
        --timeline no \
        --force || {
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Verify snapper configuration was created
    if [ ! -f "/etc/snapper/configs/var" ]; then
        echo "✗ Snapper configuration for 'var' was not created"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Snapper configuration was created successfully"
    
    # Check timeline settings
    if ! grep -q "TIMELINE_CREATE=\"no\"" "/etc/snapper/configs/var"; then
        echo "✗ Timeline setting not properly disabled"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Timeline successfully disabled"
    
    # Clean up
    umount "$TARGET_MOUNT"
    return 0
}

# Test with custom snapshot retention
test_with_custom_retention() {
    echo "Running test: Custom snapshot retention configuration"
    
    # Reset filesystem and prepare new subvolume
    mkfs.btrfs -f "$TARGET_DEVICE" || return 1
    prepare_subvolume "@data" || return 1
    
    # Custom retention values
    local hourly=10
    local daily=14
    local weekly=8
    
    # Run the script with custom retention values
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT/@data" \
        --config-name "custom" \
        --hourly "$hourly" \
        --daily "$daily" \
        --weekly "$weekly" \
        --force || {
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Verify snapper configuration was created
    if [ ! -f "/etc/snapper/configs/custom" ]; then
        echo "✗ Snapper configuration for 'custom' was not created"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Snapper configuration was created successfully"
    
    # Check retention settings
    if ! grep -q "TIMELINE_LIMIT_HOURLY=\"$hourly\"" "/etc/snapper/configs/custom" || \
       ! grep -q "TIMELINE_LIMIT_DAILY=\"$daily\"" "/etc/snapper/configs/custom" || \
       ! grep -q "TIMELINE_LIMIT_WEEKLY=\"$weekly\"" "/etc/snapper/configs/custom"; then
        echo "✗ Retention settings not properly configured"
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Retention settings properly configured"
    
    # Clean up
    umount "$TARGET_MOUNT"
    return 0
}