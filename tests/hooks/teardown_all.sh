#!/bin/sh
# Global teardown for BTRFS Subvolume Tools tests

teardown_all() {
    echo "Cleaning up global test environment..."
    
    # Final safety check - unmount any filesystems that might still be mounted
    umount /dev/loop8 2>/dev/null || true
    umount /dev/loop9 2>/dev/null || true
    
    # Detach any loop devices that might still be in use
    losetup -d /dev/loop8 2>/dev/null || true
    losetup -d /dev/loop9 2>/dev/null || true
    
    # Restore original permissions
    chmod 660 /dev/btrfs-control 2>/dev/null || true
    
    # Clean up any global temp directory
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        echo "Removing global test temp directory: $TEST_TEMP_DIR"
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
    
    # Clean up any other temporary files or directories
    if [ -d /tmp/test-btrfs-* ]; then
        rm -rf /tmp/test-btrfs-* 2>/dev/null || true
    fi
    
    echo "Global cleanup complete"
    return 0
}