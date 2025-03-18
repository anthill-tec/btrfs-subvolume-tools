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
TARGET_MOUNT="$TEST_DIR/mnt-target"
SUBVOL_NAME="@test"
CONFIG_NAME="test"
IMAGE_SIZE="1000M"
ALLOW_USERS="testuser"
TEST_USER_ADDED=0
FAILED=0

# Print header
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}     Testing configure-snapshots script     ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Check if we're running in a container
if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
  # In container environment, skip systemd timer checks
  echo -e "${YELLOW}Running in container - skipping systemd timer tests${NC}"
  SKIP_SYSTEMD_TESTS=true
fi

# Make sure scripts exist
if [ ! -f "$SCRIPT_DIR/../bin/create-subvolume.sh" ]; then
    echo -e "${RED}Error: create-subvolume.sh script not found${NC}"
    echo -e "${YELLOW}Expected location: $SCRIPT_DIR/../bin/create-subvolume.sh${NC}"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/../bin/configure-snapshots.sh" ]; then
    echo -e "${RED}Error: configure-snapshots.sh script not found${NC}"
    echo -e "${YELLOW}Expected location: $SCRIPT_DIR/../bin/configure-snapshots.sh${NC}"
    exit 1
fi

# Check for required tools
for cmd in dd losetup mkfs.btrfs mount btrfs snapper; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: Required command '$cmd' not found${NC}"
        if [ "$cmd" = "snapper" ]; then
            echo -e "${YELLOW}Please install snapper package first${NC}"
        fi
        exit 1
    fi
done

# Check if we have root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This test script must be run with root privileges${NC}"
    exit 1
fi

# Create test user if needed
if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
    # Skip user creation in container environments
    echo "Skipping user creation in container environment"
    ALLOW_USERS="root"  # Use root instead of a test user in container
else
    # Regular user creation for non-container environments
    if ! id "$ALLOW_USERS" &>/dev/null; then
        echo -e "${YELLOW}Creating test user $ALLOW_USERS...${NC}"
        useradd -m -s /bin/bash "$ALLOW_USERS"
        TEST_USER_ADDED=1
    fi
fi

# Setup test environment
echo -e "${YELLOW}Setting up test environment...${NC}"

echo -e "Creating test directory structure..."
mkdir -p "$TARGET_MOUNT"

echo -e "Finding disk image..."
# Use find to locate the image instead of hardcoding path
TARGET_IMAGE=$(find / -name "target-disk.img" 2>/dev/null | head -n 1)

# Verify that we found the image
if [ -z "$TARGET_IMAGE" ]; then
    echo -e "${RED}Error: Could not locate target-disk.img${NC}"
    exit 1
fi

echo -e "Found target image: $TARGET_IMAGE"

echo -e "Setting up loop device..."

# Check if pre-configured loop devices are available
if [ -f "/loop_devices.conf" ]; then
    echo "Using pre-configured loop devices from host"
    source /loop_devices.conf
    TARGET_DEVICE="$TARGET_LOOP"
    echo -e "  Target device: $TARGET_DEVICE"
else
    # Check if we're in a container environment
    if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
        # Container-specific setup with explicit loop device
        echo -e "Using container-specific loop device setup"
        mknod -m 660 /dev/loop10 b 7 10 2>/dev/null || true
        losetup /dev/loop10 "$TARGET_IMAGE" || { echo "Failed to setup loop device"; exit 1; }
        TARGET_DEVICE="/dev/loop10"
    else
        # Standard setup for non-container environments
        TARGET_DEVICE=$(losetup -f --show "$TARGET_IMAGE")
    fi
    echo -e "  Target device: $TARGET_DEVICE"
fi

echo -e "Formatting device with btrfs..."
mkfs.btrfs -f "$TARGET_DEVICE"

echo -e "Mounting device..."
mount "$TARGET_DEVICE" "$TARGET_MOUNT"

# Create subvolume using the create-subvolume script
echo -e "Creating test subvolume using create-subvolume script..."
"$SCRIPT_DIR/../bin/create-subvolume.sh" \
    --target-device "$TARGET_DEVICE" \
    --target-mount "$TARGET_MOUNT" \
    --subvol-name "$SUBVOL_NAME"

echo -e "${GREEN}Test environment setup complete${NC}"
echo ""

# Run the script
echo -e "${YELLOW}Running configure-snapshots script...${NC}"
"$SCRIPT_DIR/../bin/configure-snapshots.sh" \
    --target-mount "$TARGET_MOUNT" \
    --config-name "$CONFIG_NAME" \
    --allow-users "$ALLOW_USERS" \
    --force

echo ""
echo -e "${YELLOW}Verifying results...${NC}"

# Check if snapper configuration was created
echo -e "Checking snapper configuration..."
if [ -f "/etc/snapper/configs/$CONFIG_NAME" ]; then
    echo -e "${GREEN}✓ Snapper configuration for $CONFIG_NAME was created${NC}"
else
    echo -e "${RED}✗ Snapper configuration for $CONFIG_NAME was not created${NC}"
    FAILED=1
fi

# Check if users were properly set
echo -e "Checking user permissions..."
if grep -q "ALLOW_USERS=\"$ALLOW_USERS\"" "/etc/snapper/configs/$CONFIG_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ User permissions were set correctly${NC}"
else
    echo -e "${RED}✗ User permissions were not set correctly${NC}"
    FAILED=1
fi

# Check if timeline is enabled
echo -e "Checking timeline configuration..."
if grep -q "TIMELINE_CREATE=\"yes\"" "/etc/snapper/configs/$CONFIG_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ Timeline creation is enabled${NC}"
else
    echo -e "${RED}✗ Timeline creation was not configured properly${NC}"
    FAILED=1
fi

# Check if we can create a snapshot
echo -e "Testing snapshot creation..."
if snapper -c "$CONFIG_NAME" create -d "Test snapshot" &>/dev/null; then
    echo -e "${GREEN}✓ Successfully created a test snapshot${NC}"
    
    # Check if we can list snapshots
    if snapper -c "$CONFIG_NAME" list | grep -q "Test snapshot"; then
        echo -e "${GREEN}✓ Successfully listed snapshots${NC}"
    else
        echo -e "${RED}✗ Could not list snapshots${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}✗ Failed to create a test snapshot${NC}"
    FAILED=1
fi

# Check if systemd timers are enabled (skip if in container)
if [ "$SKIP_SYSTEMD_TESTS" != "true" ]; then
  echo -e "Checking systemd timers..."
  if systemctl is-enabled snapper-timeline.timer &>/dev/null; then
    echo -e "${GREEN}✓ Snapper timeline timer is enabled${NC}"
  else
    echo -e "${RED}✗ Snapper timeline timer is not enabled${NC}"
    FAILED=1
  fi
else
  echo -e "${YELLOW}Skipped systemd timer tests due to container environment${NC}"
fi

# Cleanup
echo -e "${YELLOW}Cleaning up test environment...${NC}"

# Remove snapper config
echo -e "Removing test snapper configuration..."
if [ -f "/etc/snapper/configs/$CONFIG_NAME" ]; then
    snapper -c "$CONFIG_NAME" delete-config || true
fi

# Stop and disable systemd timers
systemctl disable --now snapper-timeline.timer &>/dev/null || true
systemctl disable --now snapper-cleanup.timer &>/dev/null || true

# Unmount and remove test filesystem
umount "$TARGET_MOUNT" || true

# Check if we're using pre-configured loop devices
if [ -f "/loop_devices.conf" ]; then
    # We don't detach pre-configured loop devices, as they're managed by the test framework
    echo -e "Skipping loop device detach for pre-configured devices"
else
    # Clean up loop devices we created in this script
    if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
        losetup -d /dev/loop10 || true
    else
        losetup -d "$TARGET_DEVICE" || true
    fi
fi

rm -rf "$TEST_DIR"

# Remove test user if we created one
if [ "$TEST_USER_ADDED" = "1" ]; then
    echo -e "Removing test user $ALLOW_USERS..."
    userdel -r "$ALLOW_USERS" &>/dev/null || true
fi

echo -e "${GREEN}Cleanup complete${NC}"

# Test results
echo ""
echo -e "${BLUE}============================================${NC}"
if [ "$FAILED" = "1" ]; then
    echo -e "${RED}     configure-snapshots Test: FAILED      ${NC}"
    exit 1
else
    echo -e "${GREEN}     configure-snapshots Test: PASSED      ${NC}"
fi
echo -e "${BLUE}============================================${NC}"