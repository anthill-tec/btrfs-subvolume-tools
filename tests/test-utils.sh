#!/bin/bash
# test_logging.sh
# A simple but effective test logging framework with assertion support
# Designed to be called by the test runner rather than individual tests

# Colors for better readability
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

# Debug mode flag - can be set from the environment
DEBUG_MODE="${DEBUG_MODE:-false}"

# Track test statistics
declare -A TEST_STATS
TEST_STATS[total]=0
TEST_STATS[passed]=0
TEST_STATS[failed]=0

# Keep track of assertions
declare -a FAILED_ASSERTIONS=()
CURRENT_TEST=""

# Initialize test logging - called by test runner
test_init() {
  local test_name="$1"
  CURRENT_TEST="$test_name"
  
  # Reset test-specific counters
  TEST_STATS[assertions]=0
  TEST_STATS[passed_assertions]=0
  TEST_STATS[failed_assertions]=0
  
  # Clear the failed assertions array for this test
  FAILED_ASSERTIONS=()
  
  # Increment total test count
  TEST_STATS[total]=$((TEST_STATS[total] + 1))
  
  # Output test header
  if [ "$DEBUG_MODE" = "true" ]; then
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
  if [ "$DEBUG_MODE" = "true" ]; then
    echo -e "${PURPLE}[DEBUG] ${message}${NC}"
  fi
  # Always write to log file if LOG_FILE is defined
  if [ -n "$LOG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $message" >> "$LOG_FILE"
  fi
}

# Log message at INFO level
logInfo() {
  local message="$1"
  echo -e "${CYAN}[INFO] ${message}${NC}"
  # Always write to log file if LOG_FILE is defined
  if [ -n "$LOG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $message" >> "$LOG_FILE"
  fi
}

# Log message at WARN level
logWarn() {
  local message="$1"
  echo -e "${YELLOW}[WARN] ${message}${NC}"
  # Always write to log file if LOG_FILE is defined
  if [ -n "$LOG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $message" >> "$LOG_FILE"
  fi
}

# Log message at ERROR level
logError() {
  local message="$1"
  echo -e "${RED}[ERROR] ${message}${NC}"
  # Always write to log file if LOG_FILE is defined
  if [ -n "$LOG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $message" >> "$LOG_FILE"
  fi
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
    if [ "$DEBUG_MODE" = "true" ]; then
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
    if [ "$DEBUG_MODE" != "true" ]; then
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
  TEST_STATS[assertions]=$((TEST_STATS[assertions] + 1))
  
  # Evaluate the condition
  eval "$condition"
  result=$?
  
  if [ $result -eq 0 ]; then
    # Assertion passed
    TEST_STATS[passed_assertions]=$((TEST_STATS[passed_assertions] + 1))
    if [ "$DEBUG_MODE" = "true" ]; then
      echo -e "  ${GREEN}✓ ASSERT PASSED:${NC} $message"
    fi
  else
    # Assertion failed
    TEST_STATS[failed_assertions]=$((TEST_STATS[failed_assertions] + 1))
    echo -e "  ${RED}✗ ASSERT FAILED:${NC} $message"
    
    # Add to failed assertions list
    FAILED_ASSERTIONS+=("$CURRENT_TEST: $message")
  fi
  
  return $result
}

# Assert that two values are equal
assertEquals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  
  # Default message if none provided
  if [ -z "$message" ]; then
    message="Expected '$expected' but got '$actual'"
  fi
  
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
  local message="$2"
  
  # Default message if none provided
  if [ -z "$message" ]; then
    message="File '$file' should exist"
  fi
  
  # Run the assertion
  assert "[ -f \"$file\" ]" "$message"
}

# Finish the test and report status - called by test runner
test_finish() {
  local test_name="${CURRENT_TEST:-Unknown}"
  
  # Calculate pass/fail
  if [ "${TEST_STATS[failed_assertions]:-0}" -eq 0 ]; then
    TEST_STATS[passed]=$((TEST_STATS[passed] + 1))
    echo -e "${GREEN}✓ TEST PASSED:${NC} $test_name (${TEST_STATS[assertions]} assertions)"
  else
    TEST_STATS[failed]=$((TEST_STATS[failed] + 1))
    echo -e "${RED}✗ TEST FAILED:${NC} $test_name (${TEST_STATS[failed_assertions]}/${TEST_STATS[assertions]} assertions failed)"
  fi
  
  # Return status (0 for pass, 1 for fail)
  return ${TEST_STATS[failed_assertions]:-0}
}

# Print summary of test results
print_test_summary() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}  TEST SUMMARY${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo -e "Total tests: ${TEST_STATS[total]}"
  echo -e "Passed:      ${GREEN}${TEST_STATS[passed]}${NC}"
  echo -e "Failed:      ${RED}${TEST_STATS[failed]}${NC}"
  echo ""
  
  # Show failed assertions if any
  if [ "${#FAILED_ASSERTIONS[@]}" -gt 0 ]; then
    echo -e "${RED}Failed assertions:${NC}"
    for ((i=0; i<${#FAILED_ASSERTIONS[@]}; i++)); do
      echo -e "  ${RED}✗${NC} ${FAILED_ASSERTIONS[$i]}"
    done
    echo ""
  fi
  
  # Return overall status (0 for all pass, 1 for any fail)
  return $((TEST_STATS[failed] > 0 ? 1 : 0))
}

# Suppress command output unless in debug mode
# Use this to wrap commands that produce unwanted output
suppress_unless_debug() {
  if [ "$DEBUG_MODE" = "true" ]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
  return $?
}