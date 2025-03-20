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

teardown() {
    echo "Cleaning up test environment..."
    
    # Stop snapper services that might be keeping the mountpoint busy
    systemctl stop snapper-timeline.timer snapper-cleanup.timer 2>/dev/null || true
    systemctl stop snapper-timeline.service snapper-cleanup.service 2>/dev/null || true
    
    # Kill any snapper processes that might be running
    pkill -f "snapper.*test" 2>/dev/null || true
    
    # Remove snapper configurations to release locks
    for config in test home var custom; do
        snapper -c "$config" delete-config 2>/dev/null || true
    done
    
    # Try to unmount with retries
    for i in 1 2 3; do
        # Check if any mounts exist under TEST_DIR
        if ! mount | grep -q "$TEST_DIR"; then
            echo "No mounts found under $TEST_DIR"
            break
        fi
        
        echo "Unmount attempt $i/3..."
        
        # List what's currently mounted
        echo "Current mounts:"
        mount | grep "$TEST_DIR"
        
        # Check what processes might be using the mount
        echo "Checking for processes using mounts:"
        lsof | grep "$TEST_DIR" || echo "No processes found using the mounts"
        
        # Try to unmount everything under TEST_DIR
        mount | grep "$TEST_DIR" | awk '{print $3}' | sort -r | while read mount_point; do
            echo "Attempting to unmount $mount_point..."
            umount "$mount_point" 2>/dev/null
        done
        
        # Flush filesystem buffers
        sync
        
        # Wait before retry
        if [ $i -lt 3 ]; then
            echo "Waiting before retry..."
            sleep 3
        fi
    done
    
    # Remove any test-specific directories
    rm -rf "$TEST_DIR" 2>/dev/null || true
    
    echo "Cleanup completed"
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
    
    # Create test users for this test
    echo "Creating test users..."
    useradd -m testuser1 2>/dev/null || true
    useradd -m testuser2 2>/dev/null || true
    
    # Test users to allow
    local test_users="testuser1,testuser2"
    
    # Run the script with user permissions
    "$SCRIPT_PATH" \
        --target-mount "$TARGET_MOUNT/@home" \
        --config-name "home" \
        --allow-users "$test_users" \
        --force || {
        # Clean up users before exiting on error
        userdel -r testuser1 2>/dev/null || true
        userdel -r testuser2 2>/dev/null || true
        umount "$TARGET_MOUNT"
        return 1
    }
    
    # Verify snapper configuration was created
    if [ ! -f "/etc/snapper/configs/home" ]; then
        echo "✗ Snapper configuration for 'home' was not created"
        userdel -r testuser1 2>/dev/null || true
        userdel -r testuser2 2>/dev/null || true
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ Snapper configuration was created successfully"
    
    # Check user permissions
    if ! grep -q "ALLOW_USERS=\"$test_users\"" "/etc/snapper/configs/home"; then
        echo "✗ User permissions not properly configured"
        userdel -r testuser1 2>/dev/null || true
        userdel -r testuser2 2>/dev/null || true
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ User permissions properly configured"
    
    # Test if users can create snapshots (optional but valuable)
    if ! su - testuser1 -c "snapper -c home create -d 'Test snapshot by testuser1'" 2>/dev/null; then
        echo "✗ User testuser1 unable to create snapshot"
        userdel -r testuser1 2>/dev/null || true
        userdel -r testuser2 2>/dev/null || true
        umount "$TARGET_MOUNT"
        return 1
    fi
    echo "✓ User permissions functional - snapshot created successfully"

    # Clean up test users
    echo "Cleaning up test users..."
    userdel -r testuser1 2>/dev/null || true
    userdel -r testuser2 2>/dev/null || true
    
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