#!/bin/bash
# Project Test Runner
# Using bash as the baseline for more powerful functionality

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
if [ -f "$SCRIPT_DIR/test-utils.sh" ]; then
    source "$SCRIPT_DIR/test-utils.sh"
else
    echo -e "${RED}Did not find test-utils script, aborting!${NC}"
fi

# Ensure we have root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This test runner must be run with root privileges${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Print header
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}      ${PROJECT_NAME} Test Suite      ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Run global setup if available
if [ -f "$TEST_DIR/global-hooks.sh" ]; then
    echo -e "${YELLOW}Running global setup...${NC}"
    # Source the setup script
    source "$TEST_DIR/global-hooks.sh"
    
    # Run the setup_all function if it exists
    if type setup_all &>/dev/null; then
        if ! setup_all; then
            echo -e "${RED}Global setup failed. Aborting tests.${NC}"
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}Did not global hooks script, ignoring!${NC}"
fi

# Track test counts
TOTAL_FILES=0
TOTAL_TESTS=0
PASSED=0
FAILED=0

# Find all test scripts (prefixed with test-)
TEST_SCRIPT_NAME=$(basename "$0")
for TEST_FILE in "$TEST_DIR"/*-test-*.sh; do
    # Skip the test runner itself and non-files
    if [ "$(basename "$TEST_FILE")" = "$TEST_SCRIPT_NAME" ] || [ ! -f "$TEST_FILE" ]; then
        continue
    fi
    
    TOTAL_FILES=$((TOTAL_FILES+1))
    FILE_NAME=$(basename "$TEST_FILE" .sh)
    FILE_NAME=${FILE_NAME#test-} # Remove test- prefix
    
    echo -e "${BLUE}Test File $TOTAL_FILES: $FILE_NAME${NC}"
    
    # Source the test file to access its functions
    source "$TEST_FILE"
    
    # Find all test_* functions in the file
    # This works in bash but not in other shells
    TEST_FUNCTIONS=()
    for FUNC in $(declare -F | awk '{print $3}' | grep -E '^test_'); do
        TEST_FUNCTIONS+=("$FUNC")
    done
    
    # If no test_* functions found, try to run the run_test function
    if [ ${#TEST_FUNCTIONS[@]} -eq 0 ]; then
        if type run_test &>/dev/null; then
            TEST_FUNCTIONS=("run_test")
            echo -e "${YELLOW}No test_* functions found, using run_test instead${NC}"
        else
            echo -e "${YELLOW}Warning: No test functions found in $FILE_NAME${NC}"
            continue
        fi
    fi
    
    # For each test function
    for TEST_FUNCTION in "${TEST_FUNCTIONS[@]}"; do
        if [ "$TEST_FUNCTION" = "run_test" ]; then
            TEST_NAME="$FILE_NAME"
        else
            TEST_NAME="${TEST_FUNCTION#test_}"  # Remove test_ prefix for display
        fi
    
        # Create a subshell for test isolation
        (
            # Run setup if it exists
            if type setup &>/dev/null; then
                if [ "$DEBUG_MODE" = "true" ]; then
                    echo -e "${YELLOW}  Setting up test environment...${NC}"
                fi
            
                if ! setup; then
                    echo -e "${RED}  Test setup failed${NC}"
                    exit 1
                fi
            fi
        
            # Initialize the test with the extracted name
            test_init "$TEST_NAME"
        
            # Run the actual test function
            $TEST_FUNCTION
            TEST_RESULT=$?
        
            # Finish the test and capture the result
            test_finish
            FINAL_RESULT=$?
        
            # Run teardown if it exists (always run, even if test failed)
            if type teardown &>/dev/null; then
                if [ "$DEBUG_MODE" = "true" ]; then
                    echo -e "${YELLOW}  Cleaning up test environment...${NC}"
                fi
            
                teardown || echo -e "${YELLOW}  Warning: Test cleanup had issues${NC}"
            fi
        
            # Return the test result
            exit $FINAL_RESULT
        )
    
        # Capture the result of the subshell
        TEST_RESULT=$?
    
        # Update counters based on result
        if [ $TEST_RESULT -eq 0 ]; then
            PASSED=$((PASSED+1))
        else
            FAILED=$((FAILED+1))
        fi
    done
    
    # Unset all functions from this test file to avoid conflicts
    for FUNC in $(declare -F | awk '{print $3}' | grep -E '^(test_|setup$|teardown$|run_test$)'); do
        unset -f "$FUNC"
    done
    echo ""
done
   
# Run the teardown_all function if it exists. This happens only if the global-hooks file has been sourced.
if type teardown_all &>/dev/null; then
    teardown_all || echo -e "${YELLOW}Warning: Global teardown had issues${NC}"
else
    echo -e "${YELLOW}Did not find a teardown_all method, ignoring!${NC}"
fi

# Print summary
# Print the test summary using the framework's function
print_test_summary