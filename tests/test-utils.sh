#!/bin/bash
# Improved Test Utilities for BTRFS Subvolume Tools
# A simple but effective test logging framework with assertion support

# Colors for better readability
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

# Debug mode flag - can be set from the environment
DEBUG=${DEBUG:-false}

# Track test statistics globally
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Keep track of assertions for the current test
ASSERTIONS=0
PASSED_ASSERTIONS=0
FAILED_ASSERTIONS=0

# Keep track of failed assertions
declare -A FAILED_ASSERTIONS_BY_TEST=()
CURRENT_TEST=""

# Initialize test logging - called at the beginning of each test
test_init() {
    local test_name="$1"
    CURRENT_TEST="$test_name"
    
    # Reset test-specific counters
    ASSERTIONS=0
    PASSED_ASSERTIONS=0
    FAILED_ASSERTIONS=0
    
    # Reset the failed assertions list for this test
    FAILED_ASSERTIONS_BY_TEST["$CURRENT_TEST"]=""
    
    # Output test header
    if [ "$DEBUG" = "true" ]; then
        echo -e "\n${BLUE}============================================${NC}"
        echo -e "${BLUE}  TEST: $test_name${NC}"
        echo -e "${BLUE}============================================${NC}"
    else
        echo -e "\n${BLUE}▶ TEST: $test_name${NC}"
    fi
}

# Log message at DEBUG level
logDebug() {
    local message="$1"
    if [ "$DEBUG" = "true" ]; then
        echo -e "${PURPLE}[DEBUG] ${message}${NC}"
    fi
}

# Log message at INFO level
logInfo() {
    local message="$1"
    # In non-debug mode, only show INFO messages that start with ✓ (success indicators)
    if [ "$DEBUG" = "true" ] || [[ "$message" == "✓"* ]] || [[ "$message" == "Running test:"* ]]; then
        echo -e "${CYAN}[INFO] ${message}${NC}"
    fi
}

# Log message at WARN level
logWarn() {
    local message="$1"
    # Always show warnings
    echo -e "${YELLOW}[WARN] ${message}${NC}"
}

# Log message at ERROR level
logError() {
    local message="$1"
    # Always show errors
    echo -e "${RED}[ERROR] ${message}${NC}"
}

# Execute a command and capture its output
# Only show output in debug mode
execCmd() {
    local cmd_desc="$1"
    local command="$2"
    
    # Log the command
    logDebug "Executing: $cmd_desc"
    logDebug "Command: $command"
    
    # Create a temporary file for output
    local temp_output=$(mktemp)
    
    # Run the command and capture output
    (
        set -o pipefail
        if [ "$DEBUG" = "true" ]; then
            # In debug mode, show real-time output
            eval "$command" 2>&1 | tee "$temp_output"
        else
            # In normal mode, capture but don't show
            eval "$command" > "$temp_output" 2>&1
        fi
    )
    local status=$?
    
    # Log the command result
    if [ $status -eq 0 ]; then
        logDebug "Command succeeded with exit code 0"
    else
        logWarn "Command failed with exit code $status"
        if [ "$DEBUG" != "true" ]; then
            # In normal mode, show output on failure
            echo -e "${YELLOW}Command output:${NC}"
            cat "$temp_output"
            echo ""
        fi
    fi
    
    # Clean up
    rm -f "$temp_output"
    
    return $status
}

# Assert that a condition is true
assert() {
    local condition="$1"
    local message="$2"
    local result
    
    # Increment assertion counter
    ASSERTIONS=$((ASSERTIONS + 1))
    
    # Evaluate the condition
    eval "$condition"
    result=$?
    
    if [ $result -eq 0 ]; then
        # Assertion passed
        PASSED_ASSERTIONS=$((PASSED_ASSERTIONS + 1))
        if [ "$DEBUG" = "true" ]; then
            echo -e "  ${GREEN}✓ ASSERT PASSED:${NC} $message"
        fi
    else
        # Assertion failed
        FAILED_ASSERTIONS=$((FAILED_ASSERTIONS + 1))
        echo -e "  ${RED}✗ ASSERT FAILED:${NC} $message"
        
        # Add to failed assertions list for this test
        if [ -n "$CURRENT_TEST" ]; then
            if [ -z "${FAILED_ASSERTIONS_BY_TEST[$CURRENT_TEST]}" ]; then
                FAILED_ASSERTIONS_BY_TEST["$CURRENT_TEST"]="$message"
            else
                FAILED_ASSERTIONS_BY_TEST["$CURRENT_TEST"]="${FAILED_ASSERTIONS_BY_TEST[$CURRENT_TEST]}
$message"
            fi
        fi
    fi
    
    return $result
}

# Assert that two values are equal
assertEquals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Expected '$expected' but got '$actual'}"
    
    # Run the assertion
    if [ "$expected" = "$actual" ]; then
        assert "true" "$message"
    else
        assert "false" "$message"
    fi
}

# Assert that a file exists
assertFileExists() {
    local file="$1"
    local message="${2:-File '$file' should exist}"
    
    # Run the assertion
    assert "[ -f \"$file\" ]" "$message"
}

# Assert that a directory exists
assertDirExists() {
    local dir="$1"
    local message="${2:-Directory '$dir' should exist}"
    
    # Run the assertion
    assert "[ -d \"$dir\" ]" "$message"
}

# Assert that a command succeeds
assertCmd() {
    local command="$1"
    local message="${2:-Command should succeed: $command}"
    
    # Run the command in a subshell
    (eval "$command" >/dev/null 2>&1)
    local status=$?
    
    # Run the assertion
    assert "[ $status -eq 0 ]" "$message"
}

# Finish the test and report status
test_finish() {
    local test_name="${CURRENT_TEST:-Unknown}"
    
    # Calculate pass/fail
    if [ $FAILED_ASSERTIONS -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "${GREEN}✓ TEST PASSED:${NC} $test_name ($ASSERTIONS assertions)"
        return 0
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "${RED}✗ TEST FAILED:${NC} $test_name ($FAILED_ASSERTIONS/$ASSERTIONS assertions failed)"
        
        # Show failed assertions for this test only
        if [ -n "${FAILED_ASSERTIONS_BY_TEST[$test_name]}" ]; then
            echo -e "${RED}Failed assertions:${NC}"
            echo "${FAILED_ASSERTIONS_BY_TEST[$test_name]}" | while IFS= read -r line; do
                echo -e "  ${RED}✗${NC} $line"
            done
        fi
        
        return 1
    fi
}

# Print summary of test results
print_test_summary() {
    # Show failed assertions if any
    local any_failures=0
    
    # Only show failures for the current test if specified
    if [ -n "$SPECIFIC_TEST_CASE" ]; then
        if [ -n "${FAILED_ASSERTIONS_BY_TEST[$SPECIFIC_TEST_CASE]}" ]; then
            any_failures=1
            echo -e "${RED}Failed assertions:${NC}"
            echo "${FAILED_ASSERTIONS_BY_TEST[$SPECIFIC_TEST_CASE]}" | while IFS= read -r line; do
                echo -e "  ${RED}✗${NC} $line"
            done
            echo ""
        fi
    else
        # Check if there are any failures in any test
        for test_name in "${!FAILED_ASSERTIONS_BY_TEST[@]}"; do
            if [ -n "${FAILED_ASSERTIONS_BY_TEST[$test_name]}" ]; then
                any_failures=1
                break
            fi
        done
        
        if [ $any_failures -eq 1 ]; then
            echo -e "${RED}Failed assertions:${NC}"
            for test_name in "${!FAILED_ASSERTIONS_BY_TEST[@]}"; do
                if [ -n "${FAILED_ASSERTIONS_BY_TEST[$test_name]}" ]; then
                    echo -e "  ${RED}Test: $test_name${NC}"
                    echo "${FAILED_ASSERTIONS_BY_TEST[$test_name]}" | while IFS= read -r line; do
                        echo -e "    ${RED}✗${NC} $line"
                    done
                fi
            done
            echo ""
        fi
    fi
    
    # Always show the test summary banner
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}------------------------------------------${NC}"
    echo -e "${BLUE}  Total Tests: ${TOTAL_TESTS}${NC}"
    echo -e "${GREEN}  Passed: ${PASSED_TESTS}${NC}"
    if [ "$FAILED_TESTS" -gt 0 ]; then
        echo -e "${RED}  Failed: ${FAILED_TESTS}${NC}"
    else
        echo -e "${BLUE}  Failed: ${FAILED_TESTS}${NC}"
    fi
    echo -e "${BLUE}===========================================${NC}"
    
    # Return overall status (0 for all pass, 1 for any fail)
    return $((FAILED_TESTS > 0 ? 1 : 0))
}

# Suppress command output unless in debug mode
# Use this to wrap commands that produce unwanted output
suppress_unless_debug() {
    if [ "$DEBUG" = "true" ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

# Process a test file and run its test functions
# This is the core function that executes tests in a file
process_test_file() {
    local TEST_FILE="$1"
    local SPECIFIC_TEST_CASE="$2"
    local FILE_NAME=$(basename "$TEST_FILE" .sh)
    
    echo -e "${BLUE}Test File: $FILE_NAME${NC}"
    
    # Reset the failed assertions array before processing this test file
    FAILED_ASSERTIONS_BY_TEST=()
    
    # Source the test file to access its functions
    source "$TEST_FILE"
    
    # Find all test_* functions in the file
    TEST_FUNCTIONS=()
    for FUNC in $(declare -F | awk '{print $3}' | grep -E '^test_'); do
        # Skip utility functions that are not actual tests
        if [[ "$FUNC" != "test_init" && "$FUNC" != "test_finish" ]]; then
            TEST_FUNCTIONS+=("$FUNC")
        fi
    done
    
    # If no test_* functions found, try to run the run_test function
    if [ ${#TEST_FUNCTIONS[@]} -eq 0 ]; then
        if type run_test &>/dev/null; then
            TEST_FUNCTIONS=("run_test")
            echo -e "${YELLOW}No test_* functions found, using run_test instead${NC}"
        else
            echo -e "${RED}No test functions found in $FILE_NAME${NC}"
            return
        fi
    fi
    
    # Run each test function
    for ((j=0; j<${#TEST_FUNCTIONS[@]}; j++)); do
        TEST_FUNCTION="${TEST_FUNCTIONS[$j]}"
        
        # If a specific test case was specified, only run that one
        if [ -n "$SPECIFIC_TEST_CASE" ]; then
            # Check both with and without test_ prefix
            if [[ "$TEST_FUNCTION" != "$SPECIFIC_TEST_CASE" && "$TEST_FUNCTION" != "test_$SPECIFIC_TEST_CASE" ]]; then
                continue
            fi
        fi
        
        echo -e "${YELLOW}Running test function: $TEST_FUNCTION${NC}"
        
        # Run the test in a subshell to isolate environment changes
        (
            # Set up the test environment
            if type setup &>/dev/null; then
                if [ "$DEBUG" = "true" ]; then
                    echo -e "${YELLOW}  Setting up test environment...${NC}"
                fi
                
                setup || {
                    echo -e "${RED}  Setup failed, skipping test${NC}"
                    exit 1
                }
            fi
            
            # Initialize the test
            test_init "$TEST_FUNCTION"
            
            # Run the actual test function
            $TEST_FUNCTION
            TEST_RESULT=$?
            
            # Finish the test with summary
            test_finish
            FINISH_RESULT=$?
            
            # Run teardown if it exists (always run, even if test failed)
            if type teardown &>/dev/null; then
                if [ "$DEBUG" = "true" ]; then
                    echo -e "${YELLOW}  Cleaning up test environment...${NC}"
                fi
                
                teardown || echo -e "${YELLOW}  Warning: Test cleanup had issues${NC}"
            fi
            
            # Return the test result
            exit $FINISH_RESULT
        )
        
        # Check the result of the subshell
        if [ $? -eq 0 ]; then
            PASSED_TESTS=$((PASSED_TESTS+1))
        else
            FAILED_TESTS=$((FAILED_TESTS+1))
        fi
        
        TOTAL_TESTS=$((TOTAL_TESTS+1))
    done
}

echo "DEBUG value in test-utils.sh: $DEBUG"