#!/bin/sh
# Global setup for BTRFS Subvolume Tools tests

setup_all() {
    echo "Preparing global test environment..."
    
    # Ensure we have root permissions
    if [ "$(id -u)" -ne 0 ]; then
        echo "${RED}Error: Tests must be run with root privileges${NC}"
        return 1
    fi
    
    # Load necessary kernel modules
    modprobe loop || {
        echo "Error: Failed to load loop module"
        return 1
    }
    
    # Ensure btrfs-control device exists with proper permissions
    if [ ! -e "/dev/btrfs-control" ]; then
        mknod -m 660 /dev/btrfs-control c 10 234 2>/dev/null || true
    fi
    chmod 666 /dev/btrfs-control 2>/dev/null || true
    
    # Ensure loop devices exist with proper permissions
    for i in 0 1 2 3 4 5 6 7 8 9 10; do
        if [ ! -e "/dev/loop$i" ]; then
            mknod -m 660 "/dev/loop$i" b 7 "$i" 2>/dev/null || true
        fi
    done
    chmod 666 /dev/loop* 2>/dev/null || true
    
    # Clean up any existing mounts/loop setups from previous test runs
    umount /dev/loop8 2>/dev/null || true
    umount /dev/loop9 2>/dev/null || true
    losetup -d /dev/loop8 2>/dev/null || true
    losetup -d /dev/loop9 2>/dev/null || true
    
    # Find disk images
    TARGET_IMAGE=$(find / -name "target-disk.img" 2>/dev/null | head -n 1)
    BACKUP_IMAGE=$(find / -name "backup-disk.img" 2>/dev/null | head -n 1)
    
    # Create environment variables for tests to use
    if [ -n "$TARGET_IMAGE" ] && [ -n "$BACKUP_IMAGE" ]; then
        export TEST_TARGET_IMAGE="$TARGET_IMAGE"
        export TEST_BACKUP_IMAGE="$BACKUP_IMAGE"
        echo "Located disk images for testing:"
        echo "  Target: $TEST_TARGET_IMAGE"
        echo "  Backup: $TEST_BACKUP_IMAGE"
    else
        echo "Warning: Could not locate test disk images"
        # Not returning error as images might be located elsewhere
    fi
    
    # Create a temp directory for tests to use if needed
    export TEST_TEMP_DIR=$(mktemp -d)
    echo "Created global test temp directory: $TEST_TEMP_DIR"
    
    return 0
}