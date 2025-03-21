#!/bin/bash

# Color output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Global setup for Project tests
setup_all() {
    echo -e "${YELLOW} Preparing global test environment...${NC}"
    
    # Ensure we have root permissions
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED} Tests must be run with root privileges${NC}"
        return 1
    fi

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
    
    
    # Find disk images
    TARGET_IMAGE=$(find / -name "target-disk.img" 2>/dev/null | head -n 1)
    BACKUP_IMAGE=$(find / -name "backup-disk.img" 2>/dev/null | head -n 1)
    
    # Create environment variables for tests to use
    if [ -n "$TARGET_IMAGE" ] && [ -n "$BACKUP_IMAGE" ]; then
        export TEST_TARGET_IMAGE="$TARGET_IMAGE"
        export TEST_BACKUP_IMAGE="$BACKUP_IMAGE"
        echo -e "${YELLOW} Located disk images for testing:${NC}"
        echo -e "${BLUE} Target: $TEST_TARGET_IMAGE${NC}"
        echo -e "${BLUE} Backup: $TEST_BACKUP_IMAGE${NC}"
    else
        echo -e "${YELLOW} Could not locate test disk images${NC}"
        # Not returning error as images might be located elsewhere
    fi
    
    # Create a temp directory for tests to use if needed
    export TEST_TEMP_DIR=$(mktemp -d)
    echo -e "${BLUE} Created global test temp directory: $TEST_TEMP_DIR${NC}"
    
    return 0
}

# Global teardown for Project tests
teardown_all() {
    echo -e "${YELLOW} Cleaning up global test environment...${NC}"
    
    # Final safety check - unmount any filesystems that might still be mounted
    umount /dev/loop8 2>/dev/null || true
    umount /dev/loop9 2>/dev/null || true
    
    # Detach any loop devices that might still be in use
    losetup -d /dev/loop8 2>/dev/null || true
    losetup -d /dev/loop9 2>/dev/null || true
    
    # Clean up any global temp directory
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        echo -e "${BLUE} Removing global test temp directory: $TEST_TEMP_DIR${NC}"
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
    
    # Clean up any other temporary files or directories
    if ls /tmp/test-*/ >/dev/null 2>&1; then
        rm -rf /tmp/test-*/ 2>/dev/null || true
    fi
    
    echo -e "${YELLOW} Global cleanup complete${NC}"
    return 0
}