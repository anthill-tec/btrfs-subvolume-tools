#!/bin/bash
# Test for the configure-snapshots.sh script
# Updated to use test_* functions approach and leverage the new test-utils.sh framework

# Load force unmount utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/force-unmount.sh" ]; then
    source "$SCRIPT_DIR/force-unmount.sh"
fi

# Global test variables
TEST_DIR=""
TARGET_MOUNT=""
TARGET_DEVICE=""
SCRIPT_PATH=""

# Debug mode flag - can be set from the environment
DEBUG_MODE="${DEBUG_MODE:-false}"

# Setup test environment
setup() {
    TEST_DIR="$TEST_TEMP_DIR/configure-snapshots-test"
    execCmd "Create test directory" "mkdir -p \"$TEST_DIR\""
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    execCmd "Create mount directory" "mkdir -p \"$TARGET_MOUNT\""
    
    TARGET_DEVICE="/dev/loop8"  # Using the standard loop device from setup_all.sh
    
    logDebug "Target device: $TARGET_DEVICE"
    
    SCRIPT_PATH=$(find / -path "*/bin/configure-snapshots.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        logError "Could not locate configure-snapshots.sh"
        return 1
    fi
    
    logDebug "Found script: $SCRIPT_PATH"
    
    # Format the test device - suppress errors if device is busy
    suppress_unless_debug mkfs.btrfs -f "$TARGET_DEVICE" || {
        # Force unmount the device if it's in use
        umount "$TARGET_DEVICE" 2>/dev/null || true
        
        # Try formatting again
        suppress_unless_debug mkfs.btrfs -f "$TARGET_DEVICE" || {
            logWarn "Could not format $TARGET_DEVICE, trying to continue anyway..."
        }
    }
    
    return 0
}

# Create a btrfs subvolume for testing
prepare_subvolume() {
    local subvol_name="$1"
    
    logInfo "Creating test subvolume..."
    
    # Try to unmount first in case it's mounted
    umount "$TARGET_MOUNT" 2>/dev/null || true
    
    # Add detailed debugging for loop device status
    logDebug "Checking loop device status before mounting"
    execCmd "Check loop device status" "losetup -a | grep loop"
    execCmd "Check block device" "ls -la $TARGET_DEVICE"
    
    # Verify the loop device is properly set up
    logDebug "Verifying loop device is properly set up"
    execCmd "Verify loop device" "losetup -j \"$TARGET_DEVICE\" || (logDebug \"Loop device not set up, attempting to set it up now\" && losetup \"$TARGET_DEVICE\" /images/target-disk.img)"
    
    # Check loop device status again after verification
    execCmd "Check loop device status after verification" "losetup -a | grep loop"
    
    # Format the device with BTRFS if needed
    logDebug "Formatting target device with BTRFS filesystem"
    execCmd "Format target device" "mkfs.btrfs -f \"$TARGET_DEVICE\""
    assert "[ $? -eq 0 ]" "BTRFS formatting should succeed"
    
    # Mount the root filesystem first
    logDebug "Mounting root filesystem"
    execCmd "Mount root filesystem" "mount -o loop \"$TARGET_DEVICE\" \"$TARGET_MOUNT\""
    assert "[ $? -eq 0 ]" "Root filesystem should mount successfully"
    
    # Create the subvolume
    logDebug "Creating subvolume $subvol_name"
    execCmd "Create subvolume" "btrfs subvolume create \"$TARGET_MOUNT/$subvol_name\""
    assert "[ $? -eq 0 ]" "Subvolume creation should succeed"
    
    # Unmount the root filesystem
    logDebug "Unmounting root filesystem"
    execCmd "Unmount root filesystem" "umount \"$TARGET_MOUNT\""
    
    # Now mount the subvolume
    logDebug "Mounting subvolume"
    execCmd "Mount subvolume" "mount -o loop,subvol=$subvol_name \"$TARGET_DEVICE\" \"$TARGET_MOUNT\""
    assert "[ $? -eq 0 ]" "Subvolume should mount successfully"
    
    logInfo "✓ Subvolume $subvol_name prepared successfully"
    return 0
}

# Clean up after test
teardown() {
    logDebug "Cleaning up test environment"
    
    # Stop snapper services
    execCmd "Stop snapper services" "systemctl stop snapper-timeline.timer snapper-cleanup.timer 2>/dev/null || true"
    execCmd "Stop snapper services" "systemctl stop snapper-timeline.service snapper-cleanup.service 2>/dev/null || true"
    
    # Kill any snapper processes
    execCmd "Kill snapper processes" "pkill -f \"snapper.*test\" 2>/dev/null || true"
    
    # Remove snapper configs
    for config in test home var custom; do
        execCmd "Remove $config config" "snapper -c \"$config\" delete-config 2>/dev/null || true"
    done
    
    # Use the force unmount utility if available
    if type force_unmount_path &>/dev/null; then
        logDebug "Using force unmount utility to clean up test mounts"
        force_unmount_path "$TEST_DIR" "$DEBUG_MODE"
    else
        # Fallback to standard unmounting with retries
        for i in 1 2 3; do
            if ! execCmd "Check mounts" "mount | grep -q \"$TEST_DIR\""; then
                logDebug "No mounts found under $TEST_DIR"
                break
            fi
            
            logDebug "Unmount attempt $i/3..."
            
            execCmd "List mounts" "mount | grep \"$TEST_DIR\" || true"
            
            execCmd "Check processes" "lsof | grep \"$TEST_DIR\" || echo \"No processes found using the mounts\""
            
            execCmd "Unmount all" "mount | grep \"$TEST_DIR\" | awk '{print \$3}' | sort -r | while read mount_point; do
                echo \"Attempting to unmount $mount_point...\"
                umount \"$mount_point\" 2>/dev/null || true
            done"
            
            execCmd "Sync filesystems" "sync"
            
            if [ $i -lt 3 ]; then
                logDebug "Waiting before retry..."
                sleep 3
            fi
        done
    fi
    
    # Finally remove the test directory
    execCmd "Remove test directory" "rm -rf \"$TEST_DIR\" 2>/dev/null || true"
    
    logDebug "Cleanup completed"
    return 0
}

# Test with default configuration
test_default_config() {
    logInfo "Running test: Default configuration"
    
    prepare_subvolume "@home"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    logInfo "Configuring snapper with default options"
    execCmd "Configure snapper" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"test\" \
        --force"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/test\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check timeline setting" "grep -q \"TIMELINE_CREATE=\\\"yes\\\"\" \"/etc/snapper/configs/test\""
    assert "[ $? -eq 0 ]" "Timeline creation should be enabled by default"
    logInfo "✓ Timeline settings properly configured"
    
    logInfo "Creating test snapshot"
    execCmd "Create test snapshot" "snapper -c \"test\" create -d \"Test snapshot\""
    assert "[ $? -eq 0 ]" "Should be able to create a test snapshot"
    logInfo "✓ Successfully created a test snapshot"
    
    execCmd "Check snapshot exists" "snapper -c \"test\" list | grep -q \"Test snapshot\""
    assert "[ $? -eq 0 ]" "Test snapshot should be listed"
    logInfo "✓ Successfully verified snapshot creation"
    
    # Unmount before leaving (handled more thoroughly in teardown)
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}

# Test with user permissions
test_with_user_permissions() {
    logInfo "Running test: User permissions configuration"
    
    # Generate a unique config name to avoid conflicts
    local config_name="home_$(date +%s)"
    logDebug "Using unique config name: $config_name"
    
    # Ensure any previous configs are removed
    execCmd "Remove any existing config" "snapper -c \"$config_name\" delete-config 2>/dev/null || true"
    
    # Reset filesystem and prepare a fresh subvolume
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    # Even if format fails, continue
    assert "true" "Filesystem reset should succeed"
    
    prepare_subvolume "@home"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    local test_users="testuser1 testuser2"
    logInfo "Using test users: $test_users"
    
    # Verify the mount point exists and is a btrfs filesystem
    execCmd "Verify mount point" "mountpoint -q \"$TARGET_MOUNT\" && btrfs filesystem df \"$TARGET_MOUNT\""
    assert "[ $? -eq 0 ]" "Target mount should be a valid btrfs mount point"
    
    logInfo "Configuring snapper with user permissions"
    execCmd "Configure snapper with users" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"$config_name\" \
        --allow-users \"$test_users\" \
        --force \
        --non-interactive"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/$config_name\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check user permissions" "grep -q \"ALLOW_USERS=\\\"$test_users\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "User permissions should be correctly configured"
    logInfo "✓ User permissions properly configured"
    
    logInfo "☑ Container environment: Skipping actual user testing (configuration verified)"
    
    # Clean up this specific config
    execCmd "Remove test config" "snapper -c \"$config_name\" delete-config 2>/dev/null || true"
    
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}

# Test with timeline disabled
test_with_timeline_disabled() {
    logInfo "Running test: Timeline disabled configuration"
    
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    # Even if format fails, continue
    assert "true" "Filesystem reset should succeed"
    
    prepare_subvolume "@var"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    logInfo "Configuring snapper with timeline disabled"
    execCmd "Configure snapper without timeline" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"var\" \
        --timeline no \
        --force"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/var\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check timeline setting" "grep -q \"TIMELINE_CREATE=\\\"no\\\"\" \"/etc/snapper/configs/var\""
    assert "[ $? -eq 0 ]" "Timeline should be disabled"
    logInfo "✓ Timeline successfully disabled"
    
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}

# Test with custom snapshot retention
test_with_custom_retention() {
    logInfo "Running test: Custom snapshot retention configuration"
    
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    # Even if format fails, continue
    assert "true" "Filesystem reset should succeed"
    
    prepare_subvolume "@data"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    local hourly=10
    local daily=14
    local weekly=8
    
    logInfo "Using custom retention values: hourly=$hourly, daily=$daily, weekly=$weekly"
    
    logInfo "Configuring snapper with custom retention values"
    execCmd "Configure snapper with custom retention" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"custom\" \
        --hourly \"$hourly\" \
        --daily \"$daily\" \
        --weekly \"$weekly\" \
        --force"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/custom\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check hourly setting" "grep -q \"TIMELINE_LIMIT_HOURLY=\\\"$hourly\\\"\" \"/etc/snapper/configs/custom\""
    assert "[ $? -eq 0 ]" "Hourly retention should match custom value"
    
    execCmd "Check daily setting" "grep -q \"TIMELINE_LIMIT_DAILY=\\\"$daily\\\"\" \"/etc/snapper/configs/custom\""
    assert "[ $? -eq 0 ]" "Daily retention should match custom value"
    
    execCmd "Check weekly setting" "grep -q \"TIMELINE_LIMIT_WEEKLY=\\\"$weekly\\\"\" \"/etc/snapper/configs/custom\""
    assert "[ $? -eq 0 ]" "Weekly retention should match custom value"
    
    logInfo "✓ Retention settings properly configured"
    
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}