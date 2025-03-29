#!/bin/bash

# Color output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Global setup for Project tests
setup_all() {
    # Use existing logging functions if available, otherwise fallback to echo
    if type logInfo >/dev/null 2>&1; then
        logInfo "Preparing global test environment..."
    else
        echo -e "${YELLOW} Preparing global test environment...${NC}"
    fi
    
    # Ensure we have root permissions
    if [ "$(id -u)" -ne 0 ]; then
        if type logError >/dev/null 2>&1; then
            logError "Tests must be run with root privileges"
        else
            echo -e "${RED} Tests must be run with root privileges${NC}"
        fi
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
        
        if type logInfo >/dev/null 2>&1; then
            logInfo "Located disk images for testing:"
            logDebug "Target: $TEST_TARGET_IMAGE"
            logDebug "Backup: $TEST_BACKUP_IMAGE"
        else
            echo -e "${YELLOW} Located disk images for testing:${NC}"
            echo -e "${BLUE} Target: $TEST_TARGET_IMAGE${NC}"
            echo -e "${BLUE} Backup: $TEST_BACKUP_IMAGE${NC}"
        fi
        
        # Explicitly set up loop devices with the disk images
        if type logInfo >/dev/null 2>&1; then
            logInfo "Setting up loop devices with disk images"
        else
            echo -e "${YELLOW} Setting up loop devices with disk images${NC}"
        fi
        
        # First detach if already in use
        losetup -d /dev/loop8 2>/dev/null || true
        losetup -d /dev/loop9 2>/dev/null || true
        
        # Set up the loop devices
        if ! losetup /dev/loop8 "$TEST_TARGET_IMAGE" 2>/dev/null; then
            if type logError >/dev/null 2>&1; then
                logError "Failed to set up /dev/loop8 with $TEST_TARGET_IMAGE"
            else
                echo -e "${RED} Failed to set up /dev/loop8 with $TEST_TARGET_IMAGE${NC}"
            fi
        fi
        
        if ! losetup /dev/loop9 "$TEST_BACKUP_IMAGE" 2>/dev/null; then
            if type logError >/dev/null 2>&1; then
                logError "Failed to set up /dev/loop9 with $TEST_BACKUP_IMAGE"
            else
                echo -e "${RED} Failed to set up /dev/loop9 with $TEST_BACKUP_IMAGE${NC}"
            fi
        fi
        
        # Verify the setup
        if type logDebug >/dev/null 2>&1; then
            logDebug "Verifying loop device setup:"
            if type execCmd >/dev/null 2>&1; then
                execCmd "Check loop device setup" "losetup -a | grep loop"
            else
                losetup -a | grep loop
            fi
        else
            echo -e "${BLUE} Verifying loop device setup:${NC}"
            losetup -a | grep loop
        fi
    else
        if type logWarn >/dev/null 2>&1; then
            logWarn "Could not locate test disk images"
        else
            echo -e "${YELLOW} Could not locate test disk images${NC}"
        fi
        # Not returning error as images might be located elsewhere
    fi
    
    # Create a temp directory for tests to use if needed
    export TEST_TEMP_DIR=$(mktemp -d)
    if type logDebug >/dev/null 2>&1; then
        logDebug "Created global test temp directory: $TEST_TEMP_DIR"
    else
        echo -e "${BLUE} Created global test temp directory: $TEST_TEMP_DIR${NC}"
    fi
    
    return 0
}

# Global teardown for Project tests
teardown_all() {
    if type logInfo >/dev/null 2>&1; then
        logInfo "Cleaning up global test environment..."
    else
        echo -e "${YELLOW} Cleaning up global test environment...${NC}"
    fi
    
    # Final safety check - unmount any filesystems that might still be mounted
    umount /dev/loop8 2>/dev/null || true
    umount /dev/loop9 2>/dev/null || true
    
    # Detach any loop devices that might still be in use
    losetup -d /dev/loop8 2>/dev/null || true
    losetup -d /dev/loop9 2>/dev/null || true
    
    # Clean up any global temp directory
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        if type logDebug >/dev/null 2>&1; then
            logDebug "Removing global test temp directory: $TEST_TEMP_DIR"
        else
            echo -e "${BLUE} Removing global test temp directory: $TEST_TEMP_DIR${NC}"
        fi
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
    
    # Clean up any other temporary files or directories
    if ls /tmp/test-*/ >/dev/null 2>&1; then
        rm -rf /tmp/test-*/ 2>/dev/null || true
    fi
    
    if type logInfo >/dev/null 2>&1; then
        logInfo "Global cleanup complete"
    else
        echo -e "${YELLOW} Global cleanup complete${NC}"
    fi
    return 0
}