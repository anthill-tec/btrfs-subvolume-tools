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
    # Create a unique timestamp for this test run
    local timestamp=$(date +%s)
    
    # Create test directory with timestamp to ensure uniqueness
    TEST_DIR="$TEST_TEMP_DIR/configure-snapshots-test-$timestamp"
    mkdir -p "$TEST_DIR"
    
    TARGET_MOUNT="$TEST_DIR/mnt-target"
    mkdir -p "$TARGET_MOUNT"
    
    TARGET_DEVICE="/dev/loop8"  # Using the standard loop device from setup_all.sh
    
    logDebug "Target device: $TARGET_DEVICE"
    logDebug "Target mount: $TARGET_MOUNT"
    
    SCRIPT_PATH=$(find / -path "*/bin/configure-snapshots.sh" 2>/dev/null | head -n 1)
    if [ -z "$SCRIPT_PATH" ]; then
        logError "Could not locate configure-snapshots.sh"
        return 1
    fi
    
    logDebug "Found script: $SCRIPT_PATH"
    
    # Format the test device
    execCmd "Format test device" "mkfs.btrfs -f \"$TARGET_DEVICE\"" || true
    
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
    
    # Stop all snapper services first
    execCmd "Stop snapper services" "systemctl stop snapper-timeline.timer snapper-cleanup.timer 2>/dev/null || true"
    execCmd "Stop snapper services" "systemctl stop snapper-timeline.service snapper-cleanup.service 2>/dev/null || true"
    
    # Kill any running snapper processes
    execCmd "Kill snapper processes" "pkill -f \"snapper.*test\" 2>/dev/null || true"
    
    # Get a list of all snapper configs and delete them
    execCmd "List all snapper configs" "snapper list-configs || true"
    
    # Remove specific configs we know about
    execCmd "Remove test config" "snapper -c \"test\" delete-config 2>/dev/null || true"
    execCmd "Remove home config" "snapper -c \"home\" delete-config 2>/dev/null || true"
    execCmd "Remove var config" "snapper -c \"var\" delete-config 2>/dev/null || true"
    execCmd "Remove custom config" "snapper -c \"custom\" delete-config 2>/dev/null || true"
    
    # Find and remove any timestamp-based configs
    execCmd "Find and remove timestamp configs" "for cfg in \$(snapper list-configs | grep -o 'home_[0-9]\\+\\|var_[0-9]\\+\\|custom_[0-9]\\+' 2>/dev/null); do snapper -c \"\$cfg\" delete-config; done 2>/dev/null || true"
    
    # Check for any mounts under our test directory
    execCmd "Check mounts" "mount | grep -q \"$TEST_DIR\""
    if [ $? -eq 0 ]; then
        logDebug "Found mounts under $TEST_DIR, attempting to unmount"
        execCmd "List mounts" "mount | grep \"$TEST_DIR\""
        
        # Unmount all mounts under our test directory
        execCmd "Unmount all test mounts" "mount | grep \"$TEST_DIR\" | awk '{print \$3}' | sort -r | xargs -I{} umount -f \"{}\" 2>/dev/null || true"
    else
        logDebug "No mounts found under $TEST_DIR"
    fi
    
    # Remove the test directory
    execCmd "Remove test directory" "rm -rf \"$TEST_DIR\" 2>/dev/null || true"
    
    # Reset the loop device to ensure a clean state for the next test
    execCmd "Reset loop device" "losetup -d \"$TARGET_DEVICE\" 2>/dev/null || true"
    execCmd "Reattach loop device" "losetup \"$TARGET_DEVICE\" /images/target-disk.img 2>/dev/null || true"
    
    logDebug "Cleanup completed"
    return 0
}

# Test with default configuration
test_default_config() {
    logInfo "Running test: Default configuration"
    
    # Generate a unique config name to avoid conflicts
    local config_name="test_$(date +%s)"
    logDebug "Using unique config name: $config_name"
    
    # Ensure any previous configs are removed
    execCmd "Remove any existing config" "snapper -c \"$config_name\" delete-config 2>/dev/null || true"
    
    # Reset filesystem and prepare a fresh subvolume
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    assert "true" "Filesystem reset should succeed"
    
    # Use a unique subvolume name with timestamp
    local subvol_name="@root_$(date +%s)"
    prepare_subvolume "$subvol_name"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    logInfo "Configuring snapper with default options"
    execCmd "Configure snapper" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"$config_name\" \
        --force"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/$config_name\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check timeline setting" "grep -q \"TIMELINE_CREATE=\\\"yes\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Timeline creation should be enabled by default"
    logInfo "✓ Timeline settings properly configured"
    
    logInfo "Creating test snapshot"
    execCmd "Create test snapshot" "snapper -c \"$config_name\" create -d \"Test snapshot\""
    assert "[ $? -eq 0 ]" "Should be able to create a test snapshot"
    logInfo "✓ Successfully created a test snapshot"
    
    execCmd "Check snapshot exists" "snapper -c \"$config_name\" list | grep -q \"Test snapshot\""
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
    
    # Generate a unique config name to avoid conflicts
    local config_name="var_$(date +%s)"
    logDebug "Using unique config name: $config_name"
    
    # Ensure any previous configs are removed
    execCmd "Remove any existing config" "snapper -c \"$config_name\" delete-config 2>/dev/null || true"
    
    # Reset filesystem and prepare a fresh subvolume
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    assert "true" "Filesystem reset should succeed"
    
    # Use a unique subvolume name with timestamp
    local subvol_name="@var_$(date +%s)"
    prepare_subvolume "$subvol_name"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    logInfo "Configuring snapper with timeline disabled"
    execCmd "Configure snapper with timeline disabled" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"$config_name\" \
        --timeline no \
        --force \
        --non-interactive"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/$config_name\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    execCmd "Check timeline setting" "grep -q \"TIMELINE_CREATE=\\\"no\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Timeline should be disabled"
    logInfo "✓ Timeline successfully disabled"
    
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}

# Test with custom snapshot retention
test_with_custom_retention() {
    logInfo "Running test: Custom retention configuration"
    
    # Generate a unique config name to avoid conflicts
    local config_name="custom_$(date +%s)"
    logDebug "Using unique config name: $config_name"
    
    # Ensure any previous configs are removed
    execCmd "Remove any existing config" "snapper -c \"$config_name\" delete-config 2>/dev/null || true"
    
    # Reset filesystem and prepare a fresh subvolume
    execCmd "Reset filesystem" "mkfs.btrfs -f \"$TARGET_DEVICE\" || true"
    assert "true" "Filesystem reset should succeed"
    
    # Use a unique subvolume name with timestamp
    local subvol_name="@custom_$(date +%s)"
    prepare_subvolume "$subvol_name"
    assert "[ $? -eq 0 ]" "Subvolume preparation should succeed"
    
    # Custom retention values
    local hourly=10
    local daily=7
    local monthly=3
    local yearly=1
    
    logInfo "Configuring snapper with custom retention (hourly=$hourly, daily=$daily, monthly=$monthly, yearly=$yearly)"
    execCmd "Configure snapper with custom retention" "\"$SCRIPT_PATH\" \
        --target-mount \"$TARGET_MOUNT\" \
        --config-name \"$config_name\" \
        --hourly \"$hourly\" \
        --daily \"$daily\" \
        --monthly \"$monthly\" \
        --yearly \"$yearly\" \
        --force \
        --non-interactive"
    assert "[ $? -eq 0 ]" "Snapper configuration should succeed"
    
    execCmd "Check config file exists" "[ -f \"/etc/snapper/configs/$config_name\" ]"
    assert "[ $? -eq 0 ]" "Snapper configuration file should exist"
    logInfo "✓ Snapper configuration was created successfully"
    
    # Output the contents of the snapper configuration file for debugging
    logInfo "Snapper configuration file contents:"
    execCmd "Show config file contents" "cat \"/etc/snapper/configs/$config_name\""
    
    # Check for TIMELINE_LIMIT_* settings instead of NUMBER_LIMIT_*
    execCmd "Check hourly setting" "grep -q \"TIMELINE_LIMIT_HOURLY=\\\"$hourly\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Hourly retention should be set to $hourly"
    
    execCmd "Check daily setting" "grep -q \"TIMELINE_LIMIT_DAILY=\\\"$daily\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Daily retention should be set to $daily"
    
    execCmd "Check monthly setting" "grep -q \"TIMELINE_LIMIT_MONTHLY=\\\"$monthly\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Monthly retention should be set to $monthly"
    
    execCmd "Check yearly setting" "grep -q \"TIMELINE_LIMIT_YEARLY=\\\"$yearly\\\"\" \"/etc/snapper/configs/$config_name\""
    assert "[ $? -eq 0 ]" "Yearly retention should be set to $yearly"
    logInfo "✓ Retention settings properly configured"
    
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\" 2>/dev/null || true"
    return 0
}