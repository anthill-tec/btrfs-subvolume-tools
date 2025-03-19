#!/bin/sh
# BTRFS Subvolume Tools Test Runner
# A reusable, shell-agnostic test framework that works with sh, bash, zsh, etc.

# Color output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Default project name if not provided
PROJECT_NAME="${PROJECT_NAME:-Project}"

# Test directory - automatically find the script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR"

# Ensure we have root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}Error: This test runner must be run with root privileges${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Print header
echo "${BLUE}============================================${NC}"
echo "${BLUE}      ${PROJECT_NAME} Test Suite      ${NC}"
echo "${BLUE}============================================${NC}"
echo ""

# Run global setup if available
if [ -f "$TEST_DIR/hooks/setup_all.sh" ]; then
    echo "${YELLOW}Running global setup...${NC}"
    # Source the setup script
    . "$TEST_DIR/hooks/setup_all.sh"
    
    # Run the setup_all function if it exists
    if type setup_all >/dev/null 2>&1; then
        if ! setup_all; then
            echo "${RED}Global setup failed. Aborting tests.${NC}"
            exit 1
        fi
    fi
fi

# Track results
TOTAL=0
PASSED=0
FAILED=0

# Find all test scripts (prefixed with test-)
TEST_SCRIPT_NAME=$(basename "$0")
for TEST_FILE in "$TEST_DIR"/test-*.sh; do
    # Skip the test runner itself and non-files
    if [ "$(basename "$TEST_FILE")" = "$TEST_SCRIPT_NAME" ] || [ ! -f "$TEST_FILE" ]; then
        continue
    fi
    
    TOTAL=$((TOTAL+1))
    TEST_NAME=$(basename "$TEST_FILE" .sh)
    TEST_NAME=${TEST_NAME#test-} # Remove test- prefix
    
    echo "${BLUE}Test $TOTAL: $TEST_NAME${NC}"
    
    # Create a clean environment for each test using a subshell
    (
        # Source test file to get its functions
        . "$TEST_FILE"
        
        # Setup phase
        if type setup >/dev/null 2>&1; then
            echo "${YELLOW}Setting up test environment...${NC}"
            if ! setup; then
                echo "${RED}Test setup failed${NC}"
                exit 1
            fi
        fi
        
        # Run the test
        if type run_test >/dev/null 2>&1; then
            if run_test; then
                TEST_RESULT=0
            else
                TEST_RESULT=1
            fi
        else
            # If no run_test function, execute the script directly
            if sh "$TEST_FILE"; then
                TEST_RESULT=0
            else
                TEST_RESULT=1
            fi
        fi
        
        # Teardown phase (always run, even if test failed)
        if type teardown >/dev/null 2>&1; then
            echo "${YELLOW}Cleaning up test environment...${NC}"
            teardown || echo "${YELLOW}Warning: Test cleanup had issues${NC}"
        fi
        
        exit $TEST_RESULT
    )
    
    # Capture the result of the subshell
    TEST_RESULT=$?
    
    if [ $TEST_RESULT -eq 0 ]; then
        PASSED=$((PASSED+1))
        echo "${GREEN}✓ Test passed${NC}"
    else
        FAILED=$((FAILED+1))
        echo "${RED}✗ Test failed${NC}"
    fi
    
    echo ""
done

# Run global teardown if available
if [ -f "$TEST_DIR/hooks/teardown_all.sh" ]; then
    echo "${YELLOW}Running global teardown...${NC}"
    # Source the teardown script
    . "$TEST_DIR/hooks/teardown_all.sh"
    
    # Run the teardown_all function if it exists
    if type teardown_all >/dev/null 2>&1; then
        teardown_all || echo "${YELLOW}Warning: Global teardown had issues${NC}"
    fi
fi

# Print summary
echo "${BLUE}============================================${NC}"
echo "${BLUE}               Test Summary                 ${NC}"
echo "${BLUE}============================================${NC}"
echo "Total tests:  $TOTAL"
echo "Passed:      ${GREEN}$PASSED${NC}"
echo "Failed:      ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo "${RED}Some tests failed. Check output for details.${NC}"
    exit 1
fi