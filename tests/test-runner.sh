#!/bin/bash

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default project name if not provided
PROJECT_NAME="${PROJECT_NAME:-Project}"

# Test directory - updated for container environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"  # In container, all test scripts are in the same directory

# Ensure we have root permissions
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This test runner must be run with root privileges${NC}"
    echo -e "Please run: sudo $0"
    exit 1
fi

# Find bash executable
if [ -f "/usr/bin/bash" ]; then
    BASH_EXEC="/usr/bin/bash"
elif [ -f "/bin/bash" ]; then
    BASH_EXEC="/bin/bash"
else
    echo "Error: Could not find bash executable"
    exit 1
fi

# Print header
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}      ${PROJECT_NAME} Test Suite      ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Find all test scripts (prefixed with test- but not including this script)
TEST_SCRIPT_NAME=$(basename "$0")
TEST_SCRIPTS=$(find "$TEST_DIR" -name "test-*.sh" ! -name "$TEST_SCRIPT_NAME" | sort)

if [ -z "$TEST_SCRIPTS" ]; then
    echo -e "${RED}Error: No test scripts found${NC}"
    echo -e "${YELLOW}Expected location: $TEST_DIR/test-*.sh${NC}"
    exit 1
fi

# Make test scripts executable
for script in $TEST_SCRIPTS; do
    chmod +x "$script"
done

# Run tests
echo -e "${YELLOW}Running test suite...${NC}"
echo ""

# Initialize counters
TOTAL=0
PASSED=0
FAILED=0

# Run all test scripts
for script in $TEST_SCRIPTS; do
    TOTAL=$((TOTAL+1))
    TEST_NAME=$(basename "$script" .sh)
    echo -e "${BLUE}Test $TOTAL: ${TEST_NAME#test-}${NC}"
    
    if "$BASH_EXEC" "$script"; then
        PASSED=$((PASSED+1))
    else
        FAILED=$((FAILED+1))
    fi
    echo ""
done

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