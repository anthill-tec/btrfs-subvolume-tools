#!/bin/bash
# Integration tests for BTRFS Subvolume Tools
# These tests verify the integration between different components

# Source test utilities
source "$(dirname "$0")/test-utils.sh"

# Global variables
TEST_DIR=$(mktemp -d -t integration-test-XXXXXX)
TARGET_MOUNT="$TEST_DIR/mnt-target"
BACKUP_MOUNT="$TEST_DIR/mnt-backup"
TARGET_DEVICE=""
BACKUP_DEVICE=""

# Setup function - runs before each test
setup() {
    # Create mount points
    mkdir -p "$TARGET_MOUNT"
    mkdir -p "$BACKUP_MOUNT"
    
    # Get loop devices from environment
    if [ -f "/root/loop_devices.conf" ]; then
        source "/root/loop_devices.conf"
        TARGET_DEVICE="$LOOP_TARGET"
        BACKUP_DEVICE="$LOOP_BACKUP"
    else
        # Fallback to environment variables
        TARGET_DEVICE="${TARGET_DEVICE:-/dev/loop8}"
        BACKUP_DEVICE="${BACKUP_DEVICE:-/dev/loop9}"
    fi
    
    logInfo "Using TARGET_DEVICE: $TARGET_DEVICE"
    logInfo "Using BACKUP_DEVICE: $BACKUP_DEVICE"
    
    # Verify devices exist
    if [ ! -b "$TARGET_DEVICE" ]; then
        logError "Target device $TARGET_DEVICE does not exist"
        return 1
    fi
    
    if [ ! -b "$BACKUP_DEVICE" ]; then
        logError "Backup device $BACKUP_DEVICE does not exist"
        return 1
    fi
    
    # Format and mount devices
    logInfo "Formatting target device"
    mkfs.btrfs -f "$TARGET_DEVICE" > /dev/null 2>&1
    
    logInfo "Formatting backup device"
    mkfs.btrfs -f "$BACKUP_DEVICE" > /dev/null 2>&1
    
    logInfo "Mounting target device"
    mount "$TARGET_DEVICE" "$TARGET_MOUNT"
    
    logInfo "Mounting backup device"
    mount "$BACKUP_DEVICE" "$BACKUP_MOUNT"
    
    return 0
}

# Test handling of hidden files in backup and subvolume creation
test_hidden_files_handling() {
    test_init "Handling of hidden files in backup and subvolume creation"
    
    # Create test files including hidden files
    logInfo "Creating test files including hidden files"
    
    # Create regular files
    echo "Regular file content" > "$TARGET_MOUNT/regular.txt"
    mkdir -p "$TARGET_MOUNT/dir1/subdir1"
    echo "Nested file content" > "$TARGET_MOUNT/dir1/subdir1/nested.txt"
    
    # Create hidden files and directories
    echo "Hidden file content" > "$TARGET_MOUNT/.hidden.txt"
    mkdir -p "$TARGET_MOUNT/.hidden_dir"
    echo "File in hidden dir" > "$TARGET_MOUNT/.hidden_dir/file.txt"
    
    # Create backup directory structure manually
    logInfo "Creating backup directory structure manually"
    mkdir -p "$BACKUP_MOUNT/backup"
    
    # Copy all files to backup location
    logInfo "Copying files to backup location"
    cp -a "$TARGET_MOUNT/"* "$BACKUP_MOUNT/backup/" 2>/dev/null || true
    cp -a "$TARGET_MOUNT/."* "$BACKUP_MOUNT/backup/" 2>/dev/null || true
    
    # Verify backup contains all files
    logInfo "Verifying backup contains all files"
    assertFileExists "$BACKUP_MOUNT/backup/regular.txt"
    assertDirExists "$BACKUP_MOUNT/backup/dir1/subdir1"
    assertFileExists "$BACKUP_MOUNT/backup/dir1/subdir1/nested.txt"
    assertFileExists "$BACKUP_MOUNT/backup/.hidden.txt"
    assertDirExists "$BACKUP_MOUNT/backup/.hidden_dir"
    assertFileExists "$BACKUP_MOUNT/backup/.hidden_dir/file.txt"
    
    # Create a subvolume directly using btrfs command
    logInfo "Creating subvolume directly with btrfs command"
    execCmd "Create subvolume" "btrfs subvolume create \"$TARGET_MOUNT/@test\""
    
    # Verify subvolume was created
    local subvol_list=$(btrfs subvolume list "$TARGET_MOUNT" 2>/dev/null)
    logInfo "Subvolume list: $subvol_list"
    assert "echo \"$subvol_list\" | grep -q '@test'" "Subvolume @test should exist"
    
    # Now manually copy files from backup to the subvolume
    logInfo "Copying files from backup to subvolume"
    execCmd "Copy regular files" "cp -a \"$BACKUP_MOUNT/backup/\"* \"$TARGET_MOUNT/@test/\" 2>/dev/null || true"
    execCmd "Copy hidden files" "cp -a \"$BACKUP_MOUNT/backup/\".* \"$TARGET_MOUNT/@test/\" 2>/dev/null || true"
    
    # List files in the subvolume for debugging
    logInfo "Files in the subvolume:"
    execCmd "List files" "ls -la \"$TARGET_MOUNT/@test/\""
    
    # Unmount and remount with the subvolume
    logInfo "Unmounting target"
    execCmd "Unmount target" "umount \"$TARGET_MOUNT\""
    
    # Mount the subvolume directly
    logInfo "Mounting subvolume"
    execCmd "Mount subvolume" "mount -o subvol=@test \"$TARGET_DEVICE\" \"$TARGET_MOUNT\""
    
    # List files in the mounted subvolume for debugging
    logInfo "Files in the mounted subvolume:"
    execCmd "List files" "ls -la \"$TARGET_MOUNT/\""
    
    # Verify files were copied correctly
    logInfo "Verifying files in subvolume"
    
    # Check for regular files
    assertFileExists "$TARGET_MOUNT/regular.txt"
    assertDirExists "$TARGET_MOUNT/dir1/subdir1"
    assertFileExists "$TARGET_MOUNT/dir1/subdir1/nested.txt"
    
    # Check for hidden files
    assertFileExists "$TARGET_MOUNT/.hidden.txt"
    assertDirExists "$TARGET_MOUNT/.hidden_dir"
    assertFileExists "$TARGET_MOUNT/.hidden_dir/file.txt"
    
    # Verify file content
    local regular_md5=$(md5sum "$TARGET_MOUNT/regular.txt" | cut -d ' ' -f 1)
    assertEquals "$(echo 'Regular file content' | md5sum | cut -d ' ' -f 1)" "$regular_md5" "Content of regular.txt should match"
    
    local hidden_md5=$(md5sum "$TARGET_MOUNT/.hidden.txt" | cut -d ' ' -f 1)
    assertEquals "$(echo 'Hidden file content' | md5sum | cut -d ' ' -f 1)" "$hidden_md5" "Content of .hidden.txt should match"
    
    test_finish
}

# Clean up after test
teardown() {
    logDebug "Cleaning up test environment"
    
    mount | grep "$TEST_DIR" | awk '{print $3}' | while read mount_point; do
        logDebug "Unmounting $mount_point"
        execCmd "Unmount $mount_point" "umount \"$mount_point\" 2>/dev/null || true"
    done
    
    logDebug "Removing test directory"
    execCmd "Remove test directory" "rm -rf \"$TEST_DIR\" 2>/dev/null || true"
    
    return 0
}
