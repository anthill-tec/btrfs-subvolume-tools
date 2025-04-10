#!/bin/bash
# Test Bootstrap Script
# This script initializes the test environment by:
# 1. Loading test utilities and functions
# 2. Exporting functions to make them available in subshells
# 3. Running the test runner with provided arguments

# Default environment variables
export DEBUG="${DEBUG:-false}"
export PROJECT_NAME="${PROJECT_NAME:-Project}"
export LOG_DIR="${LOG_DIR:-/var/log/tests}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            export DEBUG="true"
            shift
            ;;
        --log-dir=*)
            export LOG_DIR="${1#*=}"
            shift
            ;;
        *)
            # Store remaining arguments for the test runner
            break
            ;;
    esac
done

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Debug output to verify environment variables
echo "DEBUG value in bootstrap: ${DEBUG:-not set}"
echo "LOG_DIR value in bootstrap: ${LOG_DIR:-not set}"

# Enable systemd services required for tests
if command -v systemctl >/dev/null 2>&1; then
    # Enable systemd-networkd and systemd-resolved for proper networking
    systemctl enable systemd-networkd >/dev/null 2>&1 || true
    systemctl start systemd-networkd >/dev/null 2>&1 || true
    
    # Pre-enable snapper systemd timers to avoid failures during tests
    if [ -f /usr/lib/systemd/system/snapper-timeline.timer ]; then
        # Create necessary directories for systemd timers
        mkdir -p /etc/systemd/system/snapper-timeline.timer.d
        mkdir -p /etc/systemd/system/snapper-cleanup.timer.d
        
        # Create override files to make systemd happy in the container
        cat > /etc/systemd/system/snapper-timeline.timer.d/override.conf << EOF
[Unit]
ConditionPathExists=/
[Service]
Type=simple
EOF
        
        cat > /etc/systemd/system/snapper-cleanup.timer.d/override.conf << EOF
[Unit]
ConditionPathExists=/
[Service]
Type=simple
EOF
        
        # Enable the timers but don't fail if it doesn't work
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable snapper-timeline.timer >/dev/null 2>&1 || true
        systemctl enable snapper-cleanup.timer >/dev/null 2>&1 || true
    fi
fi

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
