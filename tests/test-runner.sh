#!/bin/bash
# Improved Test Runner for BTRFS Subvolume Tools
# Properly integrates with test-utils.sh framework

# Color output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Default project name if not provided
PROJECT_NAME="${PROJECT_NAME:-Project}"

# Debug mode flag - can be set from the environment
DEBUG_MODE="${DEBUG_MODE:-false}"

# Specific test to run (optional)
SPECIFIC_TEST="${1:-}"
# Specific test case to run (optional)
SPECIFIC_TEST_CASE="${2:-}"

# Test directory - automatically find the script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR"

# Load the test utilities
if [ -f "$SCRIPT_DIR/test-utils.sh" ]; then
    echo -e "${YELLOW}Sourcing test utilities from $SCRIPT_DIR/test-utils.sh${NC}"
    # Use the dot operator instead of source for better compatibility
    . "$SCRIPT_DIR/test-utils.sh"
    
    # Define fallback functions if they're not found
    if ! command -v test_init >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: test_init function not found, defining fallback${NC}"
        test_init() {
            local test_name="$1"
            echo -e "\n${BLUE}▶ TEST: $test_name${NC}"
            return 0
        }
    fi
    
    if ! command -v test_finish >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: test_finish function not found, defining fallback${NC}"
        test_finish() {
            # Print test results
            if [ "$FAILED_ASSERTIONS" -eq 0 ]; then
                echo -e "${GREEN}✓ TEST PASSED: $CURRENT_TEST${NC}"
                return 0
            else
                echo -e "${RED}✗ TEST FAILED: $CURRENT_TEST${NC}"
                return 1
            fi
        }
    fi
    
    # Define other essential functions if they're not found
    if ! command -v assert >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: assert function not found, defining fallback${NC}"
        assert() {
            local condition="$1"
            local message="${2:-Assertion failed}"
            
            if eval "$condition"; then
                echo -e "  ${GREEN}✓ $message${NC}"
                return 0
            else
                echo -e "  ${RED}✗ ASSERT FAILED: $message${NC}"
                return 1
            fi
        }
    fi
    
    echo -e "${GREEN}Test framework functions are available${NC}"
else
    echo -e "${RED}Error: Did not find test-utils.sh script, aborting!${NC}"
    exit 1
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
    echo -e "${YELLOW}Did not find global hooks script, ignoring!${NC}"
fi

# Find all test scripts (matching test- pattern)
TEST_SCRIPT_NAME=$(basename "$0")
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
TEST_FILES=()

# First, collect all test files
for TEST_FILE in "$TEST_DIR"/*test*.sh; do
    # Skip the test runner itself and non-files
    if [ "$(basename "$TEST_FILE")" = "$TEST_SCRIPT_NAME" ] || [ ! -f "$TEST_FILE" ] || [[ "$(basename "$TEST_FILE")" == *"test-utils.sh"* ]]; then
        continue
    fi
    
    # If a specific test was specified, check if it matches
    if [ -n "$SPECIFIC_TEST" ]; then
        BASENAME=$(basename "$TEST_FILE")
        
        # Try different matching patterns:
        # 1. Exact match
        # 2. Match with .sh appended
        # 3. Match ignoring numeric prefix (e.g., "02-test-")
        # 4. Match ignoring numeric prefix and with .sh appended
        if [ "$BASENAME" = "$SPECIFIC_TEST" ] || \
           [ "$BASENAME" = "${SPECIFIC_TEST}.sh" ] || \
           [[ "$BASENAME" =~ ^[0-9]+-test-.*$ && "${BASENAME#*-test-}" = "$SPECIFIC_TEST" ]] || \
           [[ "$BASENAME" =~ ^[0-9]+-test-.*$ && "${BASENAME#*-test-}" = "${SPECIFIC_TEST}.sh" ]] || \
           [[ "$BASENAME" =~ ^[0-9]+-test-.*$ && "${BASENAME#*-test-}" =~ ^${SPECIFIC_TEST}(\.sh)?$ ]]; then
            # It's a match, include this file
            TEST_FILES+=("$TEST_FILE")
            # If we found an exact match for the test suite, break the loop
            if [ "$BASENAME" = "$SPECIFIC_TEST" ] || [ "$BASENAME" = "${SPECIFIC_TEST}.sh" ]; then
                break
            fi
        fi
    else
        # No specific test specified, include all test files
        TEST_FILES+=("$TEST_FILE")
    fi
done

# Check if we found any test files
if [ ${#TEST_FILES[@]} -eq 0 ]; then
    if [ -n "$SPECIFIC_TEST" ]; then
        echo -e "${RED}Error: Specified test file '$SPECIFIC_TEST' not found${NC}"
        exit 1
    else
        echo -e "${RED}Error: No test files found${NC}"
        exit 1
    fi
fi

# If a specific test case is specified, we need to find which file contains it
if [ -n "$SPECIFIC_TEST_CASE" ]; then
    # Check if the test case name starts with "test_" prefix, if not, add it
    FULL_TEST_CASE_NAME="$SPECIFIC_TEST_CASE"
    if [[ ! "$SPECIFIC_TEST_CASE" == test_* ]]; then
        FULL_TEST_CASE_NAME="test_$SPECIFIC_TEST_CASE"
        echo -e "${YELLOW}Looking for test case as: $FULL_TEST_CASE_NAME${NC}"
    fi
    
    # If a specific test suite is specified, only search in that file
    if [ -n "$SPECIFIC_TEST" ]; then
        echo -e "${YELLOW}Searching for test case in specified test suite: $SPECIFIC_TEST${NC}"
        FOUND_TEST_CASE=false
        
        # There should be only one file in TEST_FILES array if SPECIFIC_TEST is set
        if [ ${#TEST_FILES[@]} -eq 1 ]; then
            TEST_FILE="${TEST_FILES[0]}"
            
            # Source the test file to access its functions
            source "$TEST_FILE"
            
            # Check if the specified test case exists in this file (with or without test_ prefix)
            if type "$FULL_TEST_CASE_NAME" &>/dev/null || type "$SPECIFIC_TEST_CASE" &>/dev/null; then
                # Determine which function name exists
                ACTUAL_TEST_CASE="$SPECIFIC_TEST_CASE"
                if type "$FULL_TEST_CASE_NAME" &>/dev/null; then
                    ACTUAL_TEST_CASE="$FULL_TEST_CASE_NAME"
                fi
                
                echo -e "${GREEN}Found test case '$ACTUAL_TEST_CASE' in $SPECIFIC_TEST${NC}"
                FOUND_TEST_CASE=true
                
                # Run only this test file with the specified test case
                process_test_file "$TEST_FILE" "$ACTUAL_TEST_CASE"
            else
                echo -e "${RED}Error: Test case '$SPECIFIC_TEST_CASE' not found in $SPECIFIC_TEST${NC}"
                exit 1
            fi
            
            # Unset all functions from this test file
            for FUNC in $(declare -F | awk '{print $3}' | grep -E '^test_|^run_test$|^setup$|^teardown$'); do
                unset -f "$FUNC"
            done
            
            if [ "$FOUND_TEST_CASE" = false ]; then
                echo -e "${RED}Error: Test case '$SPECIFIC_TEST_CASE' not found in $SPECIFIC_TEST${NC}"
                exit 1
            fi
            
            # Print test summary
            print_test_summary
            
            # Exit with success if no tests failed
            if [ "$FAILED_TESTS" -eq 0 ]; then
                exit 0
            else
                exit 1
            fi
        else
            echo -e "${RED}Error: Specified test suite '$SPECIFIC_TEST' not found${NC}"
            exit 1
        fi
    else
        # No specific test suite, search across all test files
        echo -e "${YELLOW}Searching for test case '$SPECIFIC_TEST_CASE' across all test files...${NC}"
        FOUND_TEST_CASE=false
        
        # Process each test file to find the specified test case
        for ((i=0; i<${#TEST_FILES[@]}; i++)); do
            TEST_FILE="${TEST_FILES[$i]}"
            
            # Source the test file to access its functions
            source "$TEST_FILE"
            
            # Check if the specified test case exists in this file (with or without test_ prefix)
            if type "$FULL_TEST_CASE_NAME" &>/dev/null || type "$SPECIFIC_TEST_CASE" &>/dev/null; then
                # Determine which function name exists
                ACTUAL_TEST_CASE="$SPECIFIC_TEST_CASE"
                if type "$FULL_TEST_CASE_NAME" &>/dev/null; then
                    ACTUAL_TEST_CASE="$FULL_TEST_CASE_NAME"
                fi
                
                echo -e "${GREEN}Found test case '$ACTUAL_TEST_CASE' in $(basename "$TEST_FILE")${NC}"
                FOUND_TEST_CASE=true
                
                # Run only this test file with the specified test case
                process_test_file "$TEST_FILE" "$ACTUAL_TEST_CASE"
                
                # Unset all functions from this test file
                for FUNC in $(declare -F | awk '{print $3}' | grep -E '^test_|^run_test$|^setup$|^teardown$'); do
                    unset -f "$FUNC"
                done
            else
                # Unset all functions from this test file
                for FUNC in $(declare -F | awk '{print $3}' | grep -E '^test_|^run_test$|^setup$|^teardown$'); do
                    unset -f "$FUNC"
                done
            fi
        done
        
        if [ "$FOUND_TEST_CASE" = false ]; then
            echo -e "${RED}Error: Test case '$SPECIFIC_TEST_CASE' not found in any test file${NC}"
            exit 1
        fi
        
        # Print test summary
        print_test_summary
        
        # Exit with success if no tests failed
        if [ "$FAILED_TESTS" -eq 0 ]; then
            exit 0
        else
            exit 1
        fi
    fi
    
    # We've already processed the test case, so exit
    exit 0
fi

# Now process each test file
for ((i=0; i<${#TEST_FILES[@]}; i++)); do
    TEST_FILE="${TEST_FILES[$i]}"
    process_test_file "$TEST_FILE" "$SPECIFIC_TEST_CASE"
done

# Print overall test summary
print_test_summary

# Exit with error if any tests failed
if [ $FAILED_TESTS -gt 0 ]; then
    exit 1
fi

exit 0