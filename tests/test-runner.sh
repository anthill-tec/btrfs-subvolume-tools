#!/bin/bash

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test directory - updated for container environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"  # In container, all test scripts are in the same directory

# Ensure we have root permissions
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This test runner must be run with root privileges${NC}"
    echo -e "Please run: sudo $0"
    exit 1
fi

# Print header
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}      BTRFS Subvolume Tools Test Suite      ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Check if test scripts exist
if [ ! -f "$TEST_DIR/test-create-subvolume.sh" ] || [ ! -f "$TEST_DIR/test-configure-snapshots.sh" ]; then
    echo -e "${RED}Error: Test scripts not found${NC}"
    echo -e "${YELLOW}Expected location: $TEST_DIR/test-*.sh${NC}"
    exit 1
fi

# Make test scripts executable
chmod +x "$TEST_DIR/test-create-subvolume.sh"
chmod +x "$TEST_DIR/test-configure-snapshots.sh"

# Run tests
echo -e "${YELLOW}Running test suite...${NC}"
echo ""

# Initialize counters
TOTAL=0
PASSED=0
FAILED=0

# Test create-subvolume
TOTAL=$((TOTAL+1))
echo -e "${BLUE}Test 1: create-subvolume${NC}"
if "$TEST_DIR/test-create-subvolume.sh"; then
    PASSED=$((PASSED+1))
else
    FAILED=$((FAILED+1))
fi
echo ""

# Test configure-snapshots
TOTAL=$((TOTAL+1))
echo -e "${BLUE}Test 2: configure-snapshots${NC}"
if "$TEST_DIR/test-configure-snapshots.sh"; then
    PASSED=$((PASSED+1))
else
    FAILED=$((FAILED+1))
fi
echo ""

# Print summary
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}               Test Summary                 ${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "Total tests:  $TOTAL"
echo -e "Passed:      ${GREEN}$PASSED${NC}"
echo -e "Failed:      ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Check output for details.${NC}"
    exit 1
fi
