#!/bin/bash
# Simple test orchestrator for BTRFS Subvolume Tools
# Runs each test suite in its own container for isolation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the logging functions
if [ -f "$PARENT_DIR/logging.sh" ]; then
    source "$PARENT_DIR/logging.sh"
else
    echo "Error: logging.sh not found"
    exit 1
fi

# Source the loop device utilities
if [ -f "$PARENT_DIR/loop-device-utils.sh" ]; then
    source "$PARENT_DIR/loop-device-utils.sh"
else
    echo "Error: loop-device-utils.sh not found"
    exit 1
fi

# Debug mode flag
DEBUG="${DEBUG:-false}"

# Results tracking
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

# Helper function to copy a file and all its dependencies
copy_with_deps() {
    local file="$1"
    local dest_dir="$2"
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    # Create destination directory
    local dir_path=$(dirname "$file")
    mkdir -p "$dest_dir$dir_path"
    
    # Copy the file
    cp "$file" "$dest_dir$dir_path/" 2>/dev/null || true
    
    # Find and copy dependencies
    ldd "$file" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read dep; do
        if [ -f "$dep" ] && [ ! -f "$dest_dir$dep" ]; then
            mkdir -p "$dest_dir$(dirname "$dep")"
            cp "$dep" "$dest_dir$(dirname "$dep")/" 2>/dev/null || true
            
            # Recursive call to get dependencies of dependencies
            copy_with_deps "$dep" "$dest_dir"
        fi
    done
}

# Discover test suites
discover_test_suites() {
    # Find all test files, exclude utility files
    find "$SCRIPT_DIR" -maxdepth 1 -name "*test*.sh" | grep -v "test-utils.sh" | grep -v "test-runner.sh" | grep -v "test-bootstrap.sh" | grep -v "test-orchestrator.sh" | grep -v "global-hooks.sh" | sort
}

# Extract simple name from test suite path
get_simple_name() {
    local suite_path="$1"
    local suite_name=$(basename "$suite_path" .sh)
    
    # Extract the simple name without numbering
    echo "$suite_name" | sed -E 's/^[0-9]+-test-//; s/^test-//'
}

# Copy of run_tests function from install.sh
run_tests() {
    local debug="${1:-false}"
    local specific_test="$2"
    local specific_test_case="$3"
    
    # Set DEBUG for the entire script environment
    DEBUG="$debug"
    export DEBUG
    
    log_phase 1 "Running tests with machinectl..."
    
    # Check if we have root privileges
    if [ "$EUID" -ne 0 ]; then
        log_phase 1 "Error: Tests must be run with root privileges"
        log_phase 1 "Please run: sudo $0 --test"
        exit 1
    fi
    
    # Clean up function declarations
    early_cleanup() {
        log_phase 1 "Performing early cleanup..."
        # Clean up any existing containers with btrfs-test prefix
        machinectl list | grep "btrfs-test-" | awk '{print $1}' | while read machine; do
            log_phase 1 "Cleaning up existing container: $machine"
            machinectl terminate "$machine" 2>/dev/null || true
            machinectl remove "$machine" 2>/dev/null || true
        done
        rm -rf "$SCRIPT_DIR/container" 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    cleanup() {
        log_phase 1 "Cleaning up test environment..."
        # Only try to clean up the container if we have a name
        if [ -n "$CONTAINER_NAME" ]; then
            log_phase 5 "Terminating container $CONTAINER_NAME"
            run_cmd 5 "Poweroff container" "machinectl poweroff \"$CONTAINER_NAME\" 2>/dev/null || true"
            sleep 2
            run_cmd 5 "Terminate container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true"
            run_cmd 5 "Remove container" "machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        fi
        
        # Clean up loop devices - pass the container name for configuration cleanup
        cleanup_loop_devices "$CONTAINER_NAME"
        
        rm -rf "$SCRIPT_DIR/container" 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    # Generate a container name prefix from PROJECT_NAME
    generate_container_prefix() {
        local project_name="$1"
        local prefix=""
        
        # If project name contains multiple words, use abbreviation
        if [[ "$project_name" == *" "* ]]; then
            # Extract first letter of each word
            for word in $project_name; do
                prefix="${prefix}${word:0:1}"
            done
            prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]')
        else
            # Use the full name if it's a single word
            prefix=$(echo "$project_name" | tr '[:upper:]' '[:lower:]')
        fi
        
        # Limit prefix length and add -test suffix
        prefix="${prefix:0:10}-test"
        echo "$prefix"
    }
    
    # Generate unique container name based on PROJECT_NAME
    CONTAINER_PREFIX=$(generate_container_prefix "$PROJECT_NAME")
    CONTAINER_NAME="${CONTAINER_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    
    # Get the current user, even when running with sudo
    CURRENT_USER=""
    if [ -n "$SUDO_USER" ]; then
        CURRENT_USER="$SUDO_USER"
    elif [ -n "$USER" ]; then
        CURRENT_USER="$USER"
    elif [ -n "$LOGNAME" ]; then
        CURRENT_USER="$LOGNAME"
    fi
    
    # Set up logging for this test session
    LOG_DIR=$(init_logging "$CONTAINER_NAME" "$CURRENT_USER")
    
    # Check if debug mode is enabled
    if [ "$debug" = "true" ]; then
        log_phase 1 "Debug mode is enabled - detailed command output will be shown"
    else
        log_phase 1 "Debug mode is disabled - only essential output will be shown"
    fi
    
    # Record start time
    TEST_START_TIME=$(date +%s)
    
    # Set up early cleanup trap for script preparation phase
    trap early_cleanup EXIT
    
    # Phase 1: Pre-installation
    log_phase 1 "Starting pre-installation phase"
    run_cmd 1 "Checking for existing test containers" "machinectl list | grep 'btrfs-test-'"
    
    # Clean up any existing containers with similar name (safety check)
    machinectl list | grep "btrfs-test-" | awk '{print $1}' | while read machine; do
        run_cmd 1 "Cleaning up existing container: $machine" "machinectl terminate \"$machine\" 2>/dev/null || true && machinectl remove \"$machine\" 2>/dev/null || true"
    done
    
    run_cmd 1 "Creating test directory structure" "mkdir -p $SCRIPT_DIR/container/rootfs"
    
    # Phase 2: Tool setup
    log_phase 2 "Starting tool setup phase"
    
    # Check for pacstrap and install if missing
    if ! command -v pacstrap >/dev/null 2>&1; then
        log_phase 2 "Pacstrap not found. Attempting to install it..."
        
        if command -v yay >/dev/null 2>&1; then
            run_cmd 2 "Installing arch-install-scripts using yay" "yay -S --noconfirm arch-install-scripts"
        elif command -v pacman >/dev/null 2>&1; then
            run_cmd 2 "Installing arch-install-scripts using pacman" "pacman -S --noconfirm arch-install-scripts"
        else
            log_phase 2 "Error: Could not install pacstrap. Neither yay nor pacman found."
            log_phase 2 "Please install arch-install-scripts package manually and try again."
            
            # Record end time and finalize logs
            TEST_END_TIME=$(date +%s)
            TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
            finalize_logs 1 "$TEST_DURATION"
            
            return 1
        fi
    fi
    
    # Verify pacstrap is now available
    if ! command -v pacstrap >/dev/null 2>&1; then
        log_phase 2 "Error: Could not find or install pacstrap."
        log_phase 2 "Please install arch-install-scripts package manually and try again."
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_logs 1 "$TEST_DURATION"
        
        return 1
    fi
    
    # Create container using pacstrap
    log_phase 2 "Using pacstrap to create base container"
    
    # Fixed command - include util-linux to ensure losetup is available
    run_cmd 2 "Installing base container with pacstrap" "pacstrap -c $SCRIPT_DIR/container/rootfs base systemd bash sudo btrfs-progs snapper snap-pac util-linux lsof"
    
    if [ $? -ne 0 ]; then
        log_phase 2 "Error: Pacstrap failed to create the container."
        log_phase 2 "Please check the logs for details."
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_logs 1 "$TEST_DURATION"
        
        return 1
    fi
    
    # After pacstrap runs, add any missing elements
    
    # Create minimal snapper config directory
    run_cmd 2 "Creating snapper config directory" "mkdir -p $SCRIPT_DIR/container/rootfs/etc/snapper/configs"
    
    # Copy bin scripts to container
    run_cmd 2 "Copying bin scripts to container" "mkdir -p $SCRIPT_DIR/container/rootfs/root/bin"
    run_cmd 2 "Copying scripts" "cp -rv $PARENT_DIR/bin/* $SCRIPT_DIR/container/rootfs/root/bin/"
    
    # Copy test scripts and utilities
    run_cmd 2 "Copying test runner" "cp -v $SCRIPT_DIR/test-runner.sh $SCRIPT_DIR/container/rootfs/root/test-runner.sh && chmod +x $SCRIPT_DIR/container/rootfs/root/test-runner.sh"
    run_cmd 2 "Copying test utilities" "cp -v $SCRIPT_DIR/test-utils.sh $SCRIPT_DIR/container/rootfs/root/test-utils.sh"
    run_cmd 2 "Copying bootstrap script" "cp -v $SCRIPT_DIR/test-bootstrap.sh $SCRIPT_DIR/container/rootfs/root/test-bootstrap.sh && chmod +x $SCRIPT_DIR/container/rootfs/root/test-bootstrap.sh"
    run_cmd 2 "Copying global hooks" "cp -v $SCRIPT_DIR/global-hooks.sh $SCRIPT_DIR/container/rootfs/root/global-hooks.sh"
    
    # Copy all test scripts generically
    run_cmd 2 "Copying all test scripts" "find $SCRIPT_DIR/ -maxdepth 1 -name '*test*.sh' -not -name 'test-runner.sh' -not -name 'test-bootstrap.sh' | xargs -I{} cp -v {} $SCRIPT_DIR/container/rootfs/root/ && chmod +x $SCRIPT_DIR/container/rootfs/root/*test*.sh"
    
    # Create test disk images
    log_phase 2 "Creating test disk images"
    # Create images directory that matches the path expected by test scripts
    run_cmd 2 "Creating images directory in container" "mkdir -p $SCRIPT_DIR/container/rootfs/images"
    run_cmd 2 "Creating target disk image" "dd if=/dev/zero of=$SCRIPT_DIR/container/rootfs/images/target-disk.img bs=1M count=500 status=none"
    run_cmd 2 "Creating backup disk image" "dd if=/dev/zero of=$SCRIPT_DIR/container/rootfs/images/backup-disk.img bs=1M count=300 status=none"
    run_cmd 2 "Flushing disk writes" "sync"
    
    # Phase 3: Test configuration
    log_phase 3 "Starting test configuration phase"
    
    # Import container filesystem
    run_cmd 3 "Importing container filesystem as $CONTAINER_NAME" "machinectl import-fs $SCRIPT_DIR/container/rootfs \"$CONTAINER_NAME\""
    if [ $? -ne 0 ]; then
        log_phase 3 "Error: Failed to import container filesystem"
        run_cmd 3 "Checking container status" "machinectl status \"$CONTAINER_NAME\""
        run_cmd 3 "Checking machined logs" "journalctl -u systemd-machined.service -n 50"
        run_cmd 3 "Checking import service logs" "journalctl -b -u importctl.service -n 50"
        
        # Clean up any partial container
        run_cmd 3 "Cleaning up partial container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_logs 1 "$TEST_DURATION"
        
        return 1
    fi
    
    # Verify container structure
    run_cmd 3 "Verifying container structure" "find $SCRIPT_DIR/container/rootfs -type d | sort | head -n 20"
    run_cmd 3 "Checking container files" "find $SCRIPT_DIR/container/rootfs -type f | grep -v 'img$' | sort | head -n 20"
    
    # Verify shell binaries exist in the container
    run_cmd 3 "Checking for shell in container" "ls -la $SCRIPT_DIR/container/rootfs/bin/sh || ls -la $SCRIPT_DIR/container/rootfs/usr/bin/sh"
    
    # Copy test files to imported container (needed because machinectl import-fs might not copy everything)
    run_cmd 3 "Creating important directories in imported container" "mkdir -p /var/lib/machines/$CONTAINER_NAME/root /var/lib/machines/$CONTAINER_NAME/images"
    run_cmd 3 "Copying test scripts to imported container" "cp -r $SCRIPT_DIR/container/rootfs/root/* /var/lib/machines/$CONTAINER_NAME/root/"
    run_cmd 3 "Copying test images" "cp $SCRIPT_DIR/container/rootfs/images/*.img /var/lib/machines/$CONTAINER_NAME/images/"
    
    # Prepare for loop device setup
    run_cmd 3 "Preparing container and loop devices" "mkdir -p /etc/systemd/nspawn"
    
    # Apply loop device fixes
    apply_loop_device_fixes "$CONTAINER_NAME"
    
    # Start the container using machinectl
    run_cmd 3 "Starting container" "machinectl start \"$CONTAINER_NAME\""
    
    # Wait for container to be fully running - disable trap during waiting
    trap - EXIT
    log_phase 3 "Waiting for container to start..."
    CONTAINER_READY=false
    for i in {1..30}; do
        # Improved container readiness detection
        if machinectl status "$CONTAINER_NAME" 2>/dev/null | grep -q "Multi-User System"; then
            # Try to execute a simple command in the container to verify it's responsive
            if machinectl shell "$CONTAINER_NAME" /bin/true >/dev/null 2>&1; then
                run_cmd 3 "Container is now running and responsive" "machinectl status \"$CONTAINER_NAME\""
                CONTAINER_READY=true
                break
            fi
        fi
        run_cmd 3 "Waiting attempt $i/30" "machinectl status \"$CONTAINER_NAME\""
        sleep 2
    done

    # Verify container is running
    if [ "$CONTAINER_READY" != "true" ]; then
        log_phase 3 "Error: Container failed to start properly. Check system logs."
        run_cmd 3 "Checking systemd-machined logs" "journalctl -u systemd-machined.service -n 100"
        run_cmd 3 "Final container status" "machinectl status \"$CONTAINER_NAME\" || true"
        
        run_cmd 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_logs 1 "$TEST_DURATION"
        
        trap early_cleanup EXIT
        return 1
    fi
    
    # Create the expected directory structure for images in the container
    run_cmd 3 "Creating expected image structure in container" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'mkdir -p /images && ln -sf /var/lib/machines/$CONTAINER_NAME/images/* /images/'"
    
    # Make sure loop_devices.conf is accessible in the container
    run_cmd 3 "Copying loop device configuration to container root" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'cp /loop_devices.conf / && chmod 644 /loop_devices.conf'"
    
    # Container is running, reinstall the proper cleanup trap
    log_phase 3 "Container is running, proceeding with tests..."
    trap cleanup EXIT
    
    # Phase 4: Test execution
    log_phase 4 "Starting test execution phase"
    
    # Clear visual separation before starting tests
    if [ "$debug" != "true" ]; then
        log_phase 4 ""
        log_phase 4 "=============== RUNNING TESTS ==============="
        log_phase 4 ""
    fi
    
    # Run tests in the container
    log_phase 4 "Running tests in container $CONTAINER_NAME"
    
    # Get container info for better debugging
    run_cmd 4 "Getting container status" "machinectl status \"$CONTAINER_NAME\""
    
    # Check shell availability in the container
    run_cmd 4 "Checking shell in container" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'ls -la /bin/sh || ls -la /usr/bin/sh'"
    
    # List test scripts inside the container to verify they were copied correctly
    run_cmd 4 "Listing test scripts in container" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'ls -la /root/test*.sh'"
    
    # Verify the directory structure and loop devices
    run_cmd 4 "Verifying image symlinks" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'ls -la /images/'"
    run_cmd 4 "Checking loop device availability" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'ls -la /dev/loop* || echo \"No loop devices found\"'"
    run_cmd 4 "Checking loop_devices.conf" "machinectl shell \"$CONTAINER_NAME\" /bin/sh -c 'cat /loop_devices.conf || echo \"No loop_devices.conf found\"'"
    
    # Execute the test runner
    log_phase 4 "Starting test execution phase"
    
    # Pass DEBUG as a command line argument to the bootstrap script
    if [ "$DEBUG" = "true" ]; then
        debug_arg="--debug"
    else
        debug_arg=""
    fi
    
    # Execute the command with the debug flag if needed and pass PROJECT_NAME
    run_cmd 4 "Running tests in container with /bin/bash" \
        "machinectl shell \"$CONTAINER_NAME\" /bin/bash -c 'cd /root && PROJECT_NAME=\"$PROJECT_NAME\" LOG_DIR=\"$LOG_DIR\" ./test-bootstrap.sh $debug_arg ${specific_test:-} ${specific_test_case:-}'"
    
    # Get test exit code
    TEST_RESULT=$?
    
    # Check if tests reported failures
    if [ "$DEBUG" = "true" ]; then
        # In debug mode, check the detailed log file
        if grep -q "TEST FAILED:" "$LOG_DIR/04_test_execution.log" 2>/dev/null || grep -q "Failed: [1-9]" "$LOG_DIR/04_test_execution.log" 2>/dev/null; then
            log_phase 4 "Test script reported failures"
            TEST_RESULT=1
        fi
    else
        # In normal mode, check the test_output.log file
        if grep -q "TEST FAILED:" "$LOG_DIR/test_output.log" 2>/dev/null || grep -q "Failed: [1-9]" "$LOG_DIR/test_output.log" 2>/dev/null; then
            log_phase 4 "Test script reported failures"
            TEST_RESULT=1
        fi
    fi
    
    # Phase 5: Cleanup and results
    log_phase 5 "Starting cleanup and results phase"
    
    # Clean up the container if it's still running disable the trap handler during a normal exit. 
    # This is to make sure that $CONTAINER_NAME is available during cleanup and that a proper clean up happens if we didnt drop out of the main shell process.
    trap - EXIT 
    cleanup
    
    # Record end time
    TEST_END_TIME=$(date +%s)
    TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
    
    # Finalize logs
    log_phase 5 "Finalizing test results"
    
    # Add final summary to the log
    finalize_logs $TEST_RESULT "$TEST_DURATION"
    
    # Display test location to user
    log_phase 5 "Test logs saved to: $LOG_DIR"
    
    return $TEST_RESULT
}

# Main function
main() {
    # Check if we have root privileges
    if [ "$(id -u)" -ne 0 ]; then
        log_phase 1 "Error: Tests must be run with root privileges"
        log_phase 1 "Please run: sudo $0"
        exit 1
    fi
    
    # Variables for test suite and case
    SPECIFIC_TEST=""
    SPECIFIC_TEST_CASE=""
    PROJECT_NAME=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug)
                DEBUG=true
                shift
                ;;
            --test-suite=*)
                SPECIFIC_TEST="${1#*=}"
                shift
                ;;
            --test-case=*)
                SPECIFIC_TEST_CASE="${1#*=}"
                shift
                ;;
            --project-name=*)
                # Extract the project name, preserving spaces
                PROJECT_NAME="${1#--project-name=}"
                shift
                ;;
            *)
                log_phase 1 "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # If a specific test suite is specified, only run that one
    if [ -n "$SPECIFIC_TEST" ]; then
        log_phase 1 "Running specific test suite: $SPECIFIC_TEST"
        if [ -n "$SPECIFIC_TEST_CASE" ]; then
            log_phase 1 "Running specific test case: $SPECIFIC_TEST_CASE"
            run_tests "$DEBUG" "$SPECIFIC_TEST" "$SPECIFIC_TEST_CASE"
            exit $?
        else
            run_tests "$DEBUG" "$SPECIFIC_TEST" ""
            exit $?
        fi
    fi
    
    # Discover test suites
    mapfile -t TEST_SUITES < <(discover_test_suites)
    
    if [ ${#TEST_SUITES[@]} -eq 0 ]; then
        log_phase 1 "Error: No test suites found"
        exit 1
    fi
    
    log_phase 1 "Found ${#TEST_SUITES[@]} test suites to run"
    for test_suite in "${TEST_SUITES[@]}"; do
        log_phase 2 "  - $(get_simple_name "$test_suite")"
    done
    
    # Run each test suite in its own container
    for test_suite in "${TEST_SUITES[@]}"; do
        SUITE_NAME=$(get_simple_name "$test_suite")
        log_phase 1 "Running test suite: $SUITE_NAME"
        
        # Run the test suite using the copied run_tests function
        run_tests "$DEBUG" "$SUITE_NAME" ""
        
        RESULT=$?
        TOTAL_SUITES=$((TOTAL_SUITES + 1))
        
        if [ $RESULT -eq 0 ]; then
            PASSED_SUITES=$((PASSED_SUITES + 1))
            log_phase 5 "✓ Test suite passed: $SUITE_NAME"
        else
            FAILED_SUITES=$((FAILED_SUITES + 1))
            log_phase 5 "✗ Test suite failed: $SUITE_NAME"
        fi
        
        # Add a 5-second delay to ensure container resources are fully released
        sleep 5
    done
    
    # Print summary using the new bannerized function
    log_orchestration_summary "$TOTAL_SUITES" "$PASSED_SUITES" "$FAILED_SUITES"
    SUMMARY_RESULT=$?
    
    if [ $FAILED_SUITES -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Run main function
main "$@"
