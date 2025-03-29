#!/bin/bash
# Remove the set -e to prevent premature exits on command failures
# We'll handle errors explicitly instead

PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the logging functions
if [ -f "$SCRIPT_DIR/logging.sh" ]; then
    source "$SCRIPT_DIR/logging.sh"
else
    echo "Error: logging.sh not found"
    exit 1
fi

# Source the loop device utilities
if [ -f "$SCRIPT_DIR/loop-device-utils.sh" ]; then
    source "$SCRIPT_DIR/loop-device-utils.sh"
else
    echo "Error: loop-device-utils.sh not found"
    exit 1
fi

# Define subroutines

# Display help information
show_help() {
    echo "BTRFS Subvolume Tools Installer"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help           Show this help message"
    echo "  --test           Run all tests instead of installing"
    echo "  --debug-test     Run all tests in debug mode"
    echo "  --test-suite=NAME  Run a specific test suite file"
    echo "  --test-case=FUNC   Run a specific test case function"
    echo "  --prefix=PATH    Install to PATH instead of /usr/local"
    echo ""
    echo "Examples:"
    echo "  $0 --test-suite=configure-snapshots"
    echo "  $0 --test-case=default_config"
    echo "  $0 --test-suite=configure-snapshots --test-case=default_config"
    echo ""
    echo "Notes:"
    echo "  - Test suite names are flexible: numeric prefixes (e.g., '02-test-') are ignored"
    echo "  - The .sh extension is optional when specifying a test suite"
    echo "  - Test case names can be specified with or without the 'test_' prefix"
    echo ""
}

# Install the software
do_install() {
    local prefix="$1"
    
    log_phase 1 "Installing btrfs-subvolume-tools to $prefix"

    # Create directories if they don't exist
    mkdir -p "$prefix/bin"
    mkdir -p "$prefix/share/man/man8"
    mkdir -p "$prefix/share/doc/btrfs-subvolume-tools"

    # Generate man pages
    if command -v pandoc >/dev/null 2>&1; then
        echo "Generating man pages with pandoc..."
        
        # Man page for create-subvolume
        if [ -f "doc/create-subvolume.md" ]; then
            echo "- Processing create-subvolume.md"
            pandoc -s -t man doc/create-subvolume.md -o /tmp/create-subvolume.8
            gzip -f /tmp/create-subvolume.8
            cp /tmp/create-subvolume.8.gz "$prefix/share/man/man8/"
            rm /tmp/create-subvolume.8.gz
        else
            echo "Warning: doc/create-subvolume.md not found, skipping man page"
        fi
        
        # Man page for configure-snapshots
        if [ -f "doc/configure-snapshots.md" ]; then
            echo "- Processing configure-snapshots.md"
            pandoc -s -t man doc/configure-snapshots.md -o /tmp/configure-snapshots.8
            gzip -f /tmp/configure-snapshots.8
            cp /tmp/configure-snapshots.8.gz "$prefix/share/man/man8/"
            rm /tmp/configure-snapshots.8.gz
        else
            echo "Warning: doc/configure-snapshots.md not found, skipping man page"
        fi
    else
        echo "Warning: pandoc not found, skipping man page installation"
    fi

    # Install scripts
    if [ -f "bin/create-subvolume.sh" ]; then
        echo "Installing create-subvolume script..."
        cp bin/create-subvolume.sh "$prefix/bin/create-subvolume"
        chmod 755 "$prefix/bin/create-subvolume"
    else
        echo "Error: bin/create-subvolume.sh not found"
        exit 1
    fi

    if [ -f "bin/configure-snapshots.sh" ]; then
        echo "Installing configure-snapshots script..."
        cp bin/configure-snapshots.sh "$prefix/bin/configure-snapshots"
        chmod 755 "$prefix/bin/configure-snapshots"
    else
        echo "Error: bin/configure-snapshots.sh not found"
        exit 1
    fi

    # Install documentation
    echo "Installing documentation..."
    for doc in README.md CHANGELOG.md LICENSE; do
        if [ -f "$doc" ]; then
            cp "$doc" "$prefix/share/doc/btrfs-subvolume-tools/"
        else
            echo "Warning: $doc not found, skipping"
        fi
    done

    # Update man database if mandb is available
    if command -v mandb >/dev/null 2>&1; then
        echo "Updating man database..."
        mandb >/dev/null 2>&1 || true
    fi

    echo "Installation completed successfully to $prefix"
    echo ""
    echo "You can now use:"
    echo "  create-subvolume    - To create and configure btrfs subvolumes"
    echo "  configure-snapshots - To set up snapper for automated snapshots"
    echo ""
    echo "See the man pages for more information:"
    echo "  man create-subvolume"
    echo "  man configure-snapshots"
}

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

# Run tests using machinectl with pacstrap
run_tests() {
    local DEBUG_MODE="${1:-false}"
    local SPECIFIC_TEST="${2:-}"
    local SPECIFIC_TEST_CASE="${3:-}"
    
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
        rm -rf tests/container 2>/dev/null || true
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
        
        rm -rf tests/container 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    # Generate unique container name
    CONTAINER_NAME="btrfs-test-$(date +%Y%m%d-%H%M%S)"
    
    # Set up logging for this test session
    LOG_DIR=$(init_logging "$CONTAINER_NAME")
    
    # Check if debug mode is enabled
    if [ "$DEBUG_MODE" = "true" ]; then
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
    
    run_cmd 1 "Creating test directory structure" "mkdir -p tests/container/rootfs"
    
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
    run_cmd 2 "Installing base container with pacstrap" "pacstrap -c tests/container/rootfs base systemd bash sudo btrfs-progs snapper snap-pac util-linux lsof"
    
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
    run_cmd 2 "Creating snapper config directory" "mkdir -p tests/container/rootfs/etc/snapper/configs"
    
    # Copy bin scripts to container
    run_cmd 2 "Copying bin scripts to container" "mkdir -p tests/container/rootfs/root/bin"
    run_cmd 2 "Copying scripts" "cp -rv $SCRIPT_DIR/bin/* tests/container/rootfs/root/bin/"
    
    # Copy test scripts directly to container without temporary files
    run_cmd 2 "Copying test-runner script" "cp -v $SCRIPT_DIR/tests/test-runner.sh tests/container/rootfs/root/test-runner.sh && chmod +x tests/container/rootfs/root/test-runner.sh"
    run_cmd 2 "Copying test-utils script" "cp -v $SCRIPT_DIR/tests/test-utils.sh tests/container/rootfs/root/test-utils.sh && chmod +x tests/container/rootfs/root/test-utils.sh"
    run_cmd 2 "Copying global hooks" "cp -v $SCRIPT_DIR/tests/global-hooks.sh tests/container/rootfs/root/global-hooks.sh"
    
    # Create a wrapper script that sources test-utils.sh and exports the functions
    cat > tests/container/rootfs/root/run-tests-wrapper.sh << 'EOF'
#!/bin/bash
# Wrapper script to ensure test functions are properly exported

# Source the test utilities
source ./test-utils.sh

# Export all test functions
export -f test_init test_finish assert assertEquals assertFileExists assertDirExists assertCmd print_test_summary suppress_unless_debug

# Run the test runner with any arguments passed to this script
./test-runner.sh "$@"
EOF
    run_cmd 2 "Creating test wrapper script" "chmod +x tests/container/rootfs/root/run-tests-wrapper.sh"
    
    # Copy all test scripts generically
    run_cmd 2 "Copying all test scripts" "find tests/ -maxdepth 1 -name '*test*.sh' -not -name 'test-runner.sh' | xargs -I{} cp -v {} tests/container/rootfs/root/ && chmod +x tests/container/rootfs/root/*test*.sh"

    # Create test disk images
    log_phase 2 "Creating test disk images"
    # Create images directory that matches the path expected by test scripts
    run_cmd 2 "Creating images directory in container" "mkdir -p tests/container/rootfs/images"
    run_cmd 2 "Creating target disk image" "dd if=/dev/zero of=tests/container/rootfs/images/target-disk.img bs=1M count=500 status=none"
    run_cmd 2 "Creating backup disk image" "dd if=/dev/zero of=tests/container/rootfs/images/backup-disk.img bs=1M count=300 status=none"
    run_cmd 2 "Flushing disk writes" "sync"
    
    # Phase 3: Test configuration
    log_phase 3 "Starting test configuration phase"
    
    # Import container filesystem
    run_cmd 3 "Importing container filesystem as $CONTAINER_NAME" "machinectl import-fs tests/container/rootfs \"$CONTAINER_NAME\""
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
    run_cmd 3 "Verifying container structure" "find tests/container/rootfs -type d | sort | head -n 20"
    run_cmd 3 "Checking container files" "find tests/container/rootfs -type f | grep -v 'img$' | sort | head -n 20"
    
    # Verify shell binaries exist in the container
    run_cmd 3 "Checking for shell in container" "ls -la tests/container/rootfs/bin/sh || ls -la tests/container/rootfs/usr/bin/sh"
    
    # Copy test files to imported container (needed because machinectl import-fs might not copy everything)
    run_cmd 3 "Creating important directories in imported container" "mkdir -p /var/lib/machines/$CONTAINER_NAME/root /var/lib/machines/$CONTAINER_NAME/images"
    run_cmd 3 "Copying test scripts to imported container" "cp -r tests/container/rootfs/root/* /var/lib/machines/$CONTAINER_NAME/root/"
    run_cmd 3 "Copying test images" "cp tests/container/rootfs/images/*.img /var/lib/machines/$CONTAINER_NAME/images/"
    
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
    
    # Create a file to capture test output
    # TEST_OUTPUT_FILE="$LOG_DIR/test_output.txt"
    # > "$TEST_OUTPUT_FILE"

    # Clear visual separation before starting tests
    if [ "$DEBUG_MODE" != "true" ]; then
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
    
    # Export DEBUG_MODE and PROJECT_NAME to ensure they're available in the container
    DEBUG_PARAM=""
    if [ "$DEBUG_MODE" = "true" ]; then
        DEBUG_PARAM="DEBUG_MODE=true"
    else
        DEBUG_PARAM="DEBUG_MODE=false"
    fi

    # Execute the test runner
    log_phase 4 "Starting test execution phase"
    if [ "$DEBUG_MODE" = "true" ]; then
        # In debug mode, show output in real-time
        run_cmd 4 "Running tests in container with /bin/bash" \
            "machinectl shell \"$CONTAINER_NAME\" /bin/bash -c 'cd /root && export $DEBUG_PARAM && export PROJECT_NAME=\"${PROJECT_NAME:-Project}\" && /bin/bash ./test-bootstrap.sh ${SPECIFIC_TEST:-} ${SPECIFIC_TEST_CASE:-}'"
    else
        # In normal mode, show only the test output
        log_phase 4 "Test output"
        run_cmd 4 "Running tests in container with /bin/bash" \
            "machinectl shell \"$CONTAINER_NAME\" /bin/bash -c 'cd /root && export $DEBUG_PARAM && export PROJECT_NAME=\"${PROJECT_NAME:-Project}\" && /bin/bash ./test-bootstrap.sh ${SPECIFIC_TEST:-} ${SPECIFIC_TEST_CASE:-}'"
    fi
    TEST_RESULT=$?

    # Check if tests reported failures
    if [ "$DEBUG_MODE" = "true" ]; then
        # In debug mode, check the detailed log file
        if grep -q "Some tests failed" "$LOG_DIR/04_test_execution.log" 2>/dev/null; then
            log_phase 4 "Test script reported failures"
            TEST_RESULT=1
        fi
    else
        # In normal mode, check the test_output.log file
        if grep -q "Some tests failed" "$LOG_DIR/test_output.log" 2>/dev/null; then
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
    if [ $TEST_RESULT -eq 0 ]; then
        log_phase 5 "All tests passed!"
    else
        log_phase 5 "Some tests failed. Check logs for details."
    fi
    
    # Add final summary to the log
    finalize_logs $TEST_RESULT "$TEST_DURATION"
    
    # Display test location to user
    log_phase 5 "Test logs saved to: $LOG_DIR"
    
    return $TEST_RESULT
}

# Main function
main() {
    # Default settings
    INSTALL_MODE=true
    TEST_MODE=false
    DEBUG_MODE=false
    SPECIFIC_TEST=""
    SPECIFIC_TEST_CASE=""
    
    # Parse command line arguments
    for arg in "$@"; do
        case $arg in
            --help)
                show_help
                exit 0
                ;;
            --test)
                TEST_MODE=true
                INSTALL_MODE=false
                shift
                ;;
            --debug-test)
                TEST_MODE=true
                DEBUG_MODE=true
                INSTALL_MODE=false
                shift
                ;;
            --test-suite=*)
                TEST_MODE=true
                INSTALL_MODE=false
                SPECIFIC_TEST="${arg#*=}"
                shift
                ;;
            --test-case=*)
                TEST_MODE=true
                INSTALL_MODE=false
                SPECIFIC_TEST_CASE="${arg#*=}"
                shift
                ;;
            --prefix=*)
                PREFIX="${arg#*=}"
                shift
                ;;
        esac
    done
    
    # Either install or run tests
    if [ "$TEST_MODE" = true ]; then
        if ! run_tests "$DEBUG_MODE" "$SPECIFIC_TEST" "$SPECIFIC_TEST_CASE"; then
            log_phase 1 "Tests failed or encountered an error."
            exit 1
        fi
    elif [ "$INSTALL_MODE" = true ]; then
        if ! do_install "$PREFIX"; then
            log_phase 1 "Installation failed."
            exit 1
        fi
    fi
    
    exit 0
}

# Run main function
main "$@"