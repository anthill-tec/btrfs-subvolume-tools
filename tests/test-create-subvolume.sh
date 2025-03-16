#!/bin/bash
set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test settings
TEST_DIR=$(mktemp -d)
SCRIPT_DIR="/root/bin"
TARGET_DEVICE=""
BACKUP_DEVICE=""
TARGET_MOUNT="$TEST_DIR/mnt-target"
BACKUP_MOUNT="$TEST_DIR/mnt-backup"
SUBVOL_NAME="@test"
IMAGE_SIZE="1000M"
BACKUP_SIZE="500M"

# Print header
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}      Testing create-subvolume script      ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Make sure script exists
if [ ! -f "$SCRIPT_DIR/../bin/create-subvolume.sh" ]; then
    echo -e "${RED}Error: create-subvolume.sh script not found${NC}"
    echo -e "${YELLOW}Expected location: $SCRIPT_DIR/../bin/create-subvolume.sh${NC}"
    exit 1
fi

# Check for required tools
for cmd in dd losetup mkfs.btrfs mount btrfs; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: Required command '$cmd' not found${NC}"
        exit 1
    fi
done

# Setup test environment
echo -e "${YELLOW}Setting up test environment...${NC}"

echo -e "Creating test directory structure..."
mkdir -p "$TARGET_MOUNT" "$BACKUP_MOUNT"

echo -e "Creating disk images..."
TARGET_IMAGE="/root/images/target-disk.img"
BACKUP_IMAGE="/root/images/backup-disk.img"

echo -e "Setting up loop devices..."
# Check if we're in a container environment
if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
    # Container-specific setup with explicit loop devices
    echo -e "Using container-specific loop device setup"
    mknod -m 660 /dev/loop8 b 7 8 2>/dev/null || true
    losetup /dev/loop8 "$TARGET_IMAGE" || { echo "Failed to setup loop device"; exit 1; }
    TARGET_DEVICE="/dev/loop8"
    mknod -m 660 /dev/loop9 b 7 9 2>/dev/null || true
    losetup /dev/loop9 "$BACKUP_IMAGE" || { echo "Failed to setup loop device"; exit 1; }
    BACKUP_DEVICE="/dev/loop9"
else
    # Standard setup for non-container environments
    TARGET_DEVICE=$(losetup -f --show "$TARGET_IMAGE")
    BACKUP_DEVICE=$(losetup -f --show "$BACKUP_IMAGE")
fi

echo -e "Formatting devices with btrfs..."
mkfs.btrfs -f "$TARGET_DEVICE"
mkfs.btrfs -f "$BACKUP_DEVICE"

echo -e "Mounting devices..."
mount "$TARGET_DEVICE" "$TARGET_MOUNT"
mount "$BACKUP_DEVICE" "$BACKUP_MOUNT"

# Create test data
echo -e "Creating test data..."
mkdir -p "$TARGET_MOUNT/testdir"
echo "This is a test file" > "$TARGET_MOUNT/testfile.txt"
echo "Another test file" > "$TARGET_MOUNT/testdir/nested.txt"
dd if=/dev/urandom of="$TARGET_MOUNT/testdir/random.bin" bs=1M count=10 status=progress

echo -e "${GREEN}Test environment setup complete${NC}"
echo ""

# Run the script
echo -e "${YELLOW}Running create-subvolume script...${NC}"
"$SCRIPT_DIR/../bin/create-subvolume.sh" \
    --target-device "$TARGET_DEVICE" \
    --target-mount "$TARGET_MOUNT" \
    --backup-drive "$BACKUP_DEVICE" \
    --backup-mount "$BACKUP_MOUNT" \
    --subvol-name "$SUBVOL_NAME" \
    --backup

echo ""
echo -e "${YELLOW}Verifying results...${NC}"

# Check if the subvolume was created
echo -e "Checking subvolume creation..."
if btrfs subvolume list "$TARGET_MOUNT" | grep -q "$SUBVOL_NAME"; then
    echo -e "${GREEN}✓ Subvolume $SUBVOL_NAME was created successfully${NC}"
else
    echo -e "${RED}✗ Subvolume $SUBVOL_NAME was not created${NC}"
    FAILED=1
fi

# Check if data was properly copied
echo -e "Checking data integrity..."
if [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testfile.txt" ] && \
   [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testdir/nested.txt" ] && \
   [ -f "$TARGET_MOUNT/$SUBVOL_NAME/testdir/random.bin" ]; then
    echo -e "${GREEN}✓ Data files were copied to the subvolume${NC}"
    
    # Verify file contents
    if diff "$TARGET_MOUNT/testfile.txt" "$TARGET_MOUNT/$SUBVOL_NAME/testfile.txt" >/dev/null; then
        echo -e "${GREEN}✓ File content verification passed${NC}"
    else
        echo -e "${RED}✗ File content verification failed${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}✗ Not all data files were copied to the subvolume${NC}"
    FAILED=1
fi

# Check fstab entry
echo -e "Checking for fstab changes..."
if grep -q "$SUBVOL_NAME" /etc/fstab; then
    echo -e "${YELLOW}! Found fstab entry for $SUBVOL_NAME - this is expected in a real system${NC}"
    echo -e "${YELLOW}! But for this test, the fstab should not have been modified${NC}"
    FAILED=1
else
    echo -e "${GREEN}✓ System fstab was not modified during testing${NC}"
fi

# Cleanup
echo -e "${YELLOW}Cleaning up test environment...${NC}"
umount "$TARGET_MOUNT" || true
umount "$BACKUP_MOUNT" || true
# Check if we're in a container environment
if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
    losetup -d /dev/loop8 || true
    losetup -d /dev/loop9 || true
else
    losetup -d "$TARGET_DEVICE" || true
    losetup -d "$BACKUP_DEVICE" || true
fi
rm -rf "$TEST_DIR"
echo -e "${GREEN}Cleanup complete${NC}"

# Test results
echo ""
echo -e "${BLUE}============================================${NC}"
if [ "$FAILED" = "1" ]; then
    echo -e "${RED}       create-subvolume Test: FAILED       ${NC}"
    exit 1
else
    echo -e "${GREEN}       create-subvolume Test: PASSED       ${NC}"
fi
echo -e "${BLUE}============================================${NC}"
