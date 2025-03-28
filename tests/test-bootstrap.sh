#!/bin/bash
# Test Bootstrap Script
# This script initializes the test environment by:
# 1. Loading test utilities and functions
# 2. Exporting functions to make them available in subshells
# 3. Running the test runner with provided arguments

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the test utilities
if [ -f "$SCRIPT_DIR/test-utils.sh" ]; then
    echo "Sourcing test utilities from $SCRIPT_DIR/test-utils.sh"
    # Use the dot operator instead of source for better compatibility
    . "$SCRIPT_DIR/test-utils.sh"
else
    echo "Error: test-utils.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Source global hooks if available
if [ -f "$SCRIPT_DIR/global-hooks.sh" ]; then
    echo "Sourcing global hooks from $SCRIPT_DIR/global-hooks.sh"
    . "$SCRIPT_DIR/global-hooks.sh"
fi

# Export all test utility functions
export -f test_init test_finish assert assertEquals assertFileExists assertDirExists assertCmd
export -f process_test_file print_test_summary logInfo logWarn logError logDebug execCmd suppress_unless_debug

# Export global hooks if they exist
if type global_setup &>/dev/null; then
    export -f global_setup
fi

if type global_teardown &>/dev/null; then
    export -f global_teardown
fi

# Now run the test runner with the provided arguments
echo "Running test runner with arguments: $@"
"$SCRIPT_DIR/test-runner.sh" "$@"
