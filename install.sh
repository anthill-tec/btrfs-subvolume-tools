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

# Define subroutines

# Show help
show_help() {
    echo "BTRFS Subvolume Tools Installation Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help           Show this help message"
    echo "  --test           Run tests instead of installing"
    echo "  --prefix=PATH    Install to PATH instead of /usr/local"
    echo ""
}

# Install the software
do_install() {
    local prefix="$1"
    
    echo "Installing btrfs-subvolume-tools to $prefix"

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

# Run tests using machinectl
run_tests() {
    echo "Running tests with machinectl..."
    
    # Check if we have root privileges
    if [ "$EUID" -ne 0 ]; then
        echo "Error: Tests must be run with root privileges"
        echo "Please run: sudo $0 --test"
        exit 1
    fi
    
    # Clean up function declarations
    early_cleanup() {
        echo "Performing early cleanup..."
        # Clean up any existing containers with btrfs-test prefix
        machinectl list | grep "btrfs-test-" | awk '{print $1}' | while read machine; do
            echo "Cleaning up existing container: $machine"
            machinectl terminate "$machine" 2>/dev/null || true
            machinectl remove "$machine" 2>/dev/null || true
        done
        rm -rf tests/container 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    cleanup() {
        echo "Cleaning up test environment..."
        # Only try to clean up the container if we have a name
        if [ -n "$CONTAINER_NAME" ]; then
            log_phase 5 "Terminating container $CONTAINER_NAME"
            run_cmd 5 "Poweroff container" "machinectl poweroff \"$CONTAINER_NAME\" 2>/dev/null || true"
            sleep 2
            run_cmd 5 "Terminate container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true"
            run_cmd 5 "Remove container" "machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        fi
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
    
    if [ ! -d tests/container/rootfs/bin ]; then
        log_phase 2 "Setting up test container..."
        
        # Create proper OS root directory structure
        run_cmd 2 "Creating proper OS root directory structure" "mkdir -p tests/container/rootfs/{bin,sbin,lib,lib64,usr/{bin,sbin,lib},etc,var,dev,sys,proc,run,tmp,root}"
        run_cmd 2 "Setting tmp permissions" "chmod 1777 tests/container/rootfs/tmp"
        
        # Create base os-release file - important for container recognition
        run_cmd 2 "Creating os-release file" "echo 'NAME=\"BTRFS Test Container\"' > tests/container/rootfs/etc/os-release && echo 'ID=btrfs-test' >> tests/container/rootfs/etc/os-release && echo 'VERSION_ID=\"1.0\"' >> tests/container/rootfs/etc/os-release"
        
        # Create machine-id file - also important for systemd
        if command -v uuidgen &> /dev/null; then
            run_cmd 2 "Creating machine-id using uuidgen" "uuidgen | tr -d '-' > tests/container/rootfs/etc/machine-id"
        else
            run_cmd 2 "Creating machine-id using date+sha256" "echo \"$(date +%s%N | sha256sum | head -c 32)\" > tests/container/rootfs/etc/machine-id"
        fi
        
        # Setup basic devices and directories needed for container
        run_cmd 2 "Setting up basic devices" "mkdir -p tests/container/rootfs/dev/{pts,shm,mqueue}"
        run_cmd 2 "Creating null device" "mknod -m 666 tests/container/rootfs/dev/null c 1 3 || true"
        run_cmd 2 "Creating zero device" "mknod -m 666 tests/container/rootfs/dev/zero c 1 5 || true"
        run_cmd 2 "Creating random device" "mknod -m 666 tests/container/rootfs/dev/random c 1 8 || true"
        run_cmd 2 "Creating urandom device" "mknod -m 666 tests/container/rootfs/dev/urandom c 1 9 || true"
        
        # Check for pacstrap and install if missing
        if ! command -v pacstrap >/dev/null 2>&1; then
            log_phase 2 "Pacstrap not found. Attempting to install it..."
            
            if command -v yay >/dev/null 2>&1; then
                run_cmd 2 "Installing arch-install-scripts using yay" "yay -S --noconfirm arch-install-scripts"
            elif command -v pacman >/dev/null 2>&1; then
                run_cmd 2 "Installing arch-install-scripts using pacman" "pacman -S --noconfirm arch-install-scripts"
            else
                log_phase 2 "Warning: Could not install pacstrap. Falling back to manual container setup."
            fi
        fi
        
        if command -v pacstrap >/dev/null 2>&1; then
            # Fixed pacstrap command - removed the invalid -d option
            run_cmd 2 "Creating minimal Arch container using pacstrap" "pacstrap -c tests/container/rootfs base systemd bash btrfs-progs snapper"
        elif [ -f /etc/arch-release ] && command -v pacman >/dev/null 2>&1; then
            log_phase 2 "Creating minimal container environment manually"
            
            # Copy required executables and libraries
            log_phase 2 "Copying required executables and libraries"
            for pkg in coreutils bash util-linux systemd btrfs-progs snapper; do
                run_cmd 2 "Processing $pkg package" "pacman -Ql $pkg 2>/dev/null | grep -v '/$' | grep -E '/(s?bin|lib)/' | wc -l"
                pacman -Ql $pkg 2>/dev/null | grep -v '/$' | grep -E '/(s?bin|lib)/' | awk '{print $2}' | while read file; do
                    if [ -f "$file" ] && [ -x "$file" ]; then
                        run_cmd 2 "Copying $file and dependencies" "copy_with_deps \"$file\" \"tests/container/rootfs\""
                    fi
                done
            done
            
            # Create essential files
            run_cmd 2 "Creating passwd file" "echo \"root:x:0:0:root:/root:/bin/bash\" > tests/container/rootfs/etc/passwd"
            run_cmd 2 "Creating group file" "echo \"root:x:0:\" > tests/container/rootfs/etc/group"
            
            # Create minimal snapper config directory
            run_cmd 2 "Creating snapper config directory" "mkdir -p tests/container/rootfs/etc/snapper/configs"
        else
            log_phase 2 "Error: This script requires Arch Linux with either pacstrap or pacman for container creation."
            log_phase 2 "Please install Arch Linux or modify this script for your distribution."
            
            # Record end time and finalize logs
            TEST_END_TIME=$(date +%s)
            TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
            finalize_logs 1 "$TEST_DURATION"
            
            return 1
        fi
    else
        log_phase 2 "Using existing container..."
    fi
    
    # Copy bin scripts to container
    run_cmd 2 "Copying bin scripts to container" "mkdir -p tests/container/rootfs/root/bin"
    run_cmd 2 "Copying scripts" "cp -rv bin/* tests/container/rootfs/root/bin/"
    
    # Prepare test scripts for container environment
    run_cmd 2 "Preparing test scripts for container environment" "cat tests/test-runner.sh | sed 's|/bin/bash|/usr/bin/bash|g' > /tmp/test-runner.sh.tmp"
    
    # Copy the test-runner script
    run_cmd 2 "Copying test-runner script" "cp /tmp/test-runner.sh.tmp tests/container/rootfs/root/test-runner.sh && chmod +x tests/container/rootfs/root/test-runner.sh"
    
    # Find and copy all test scripts (except test-runner.sh itself)
    log_phase 2 "Copying test scripts"
    TEST_RUNNER_NAME=$(basename "$(find tests -name "test-runner.sh" | head -n 1)")
    find tests -name "test-*.sh" ! -name "$TEST_RUNNER_NAME" | while read script; do
        # Fixed quote issue in the command
        run_cmd 2 "Copying: $script" "cp \"$script\" tests/container/rootfs/root/ && chmod +x \"tests/container/rootfs/root/$(basename \"$script\")\""
    done
    
    # Create test disk images
    log_phase 2 "Creating test disk images"
    # Create images directory first - this fixes the missing directory issue
    run_cmd 2 "Creating images directory" "mkdir -p tests/container/rootfs/images"
    run_cmd 2 "Creating target disk image" "dd if=/dev/zero of=tests/container/rootfs/images/target-disk.img bs=1M count=500 status=none"
    run_cmd 2 "Creating backup disk image" "dd if=/dev/zero of=tests/container/rootfs/images/backup-disk.img bs=1M count=300 status=none"
    
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
    
    # Ensure the imported container has proper OS root structure
    # This is crucial - machinectl imports to /var/lib/machines/$CONTAINER_NAME
    run_cmd 3 "Ensuring proper OS structure in imported container" "mkdir -p /var/lib/machines/$CONTAINER_NAME/etc"
    run_cmd 3 "Creating os-release in imported location" "echo 'NAME=\"BTRFS Test Container\"' > /var/lib/machines/$CONTAINER_NAME/etc/os-release && echo 'ID=btrfs-test' >> /var/lib/machines/$CONTAINER_NAME/etc/os-release && echo 'VERSION_ID=\"1.0\"' >> /var/lib/machines/$CONTAINER_NAME/etc/os-release"
    run_cmd 3 "Creating machine-id in imported location" "uuidgen | tr -d '-' > /var/lib/machines/$CONTAINER_NAME/etc/machine-id 2>/dev/null || echo \"$(date +%s%N | sha256sum | head -c 32)\" > /var/lib/machines/$CONTAINER_NAME/etc/machine-id"
    
    # Copy important files to ensure proper container functionality
    run_cmd 3 "Copying important files to imported container" "cp -r tests/container/rootfs/bin tests/container/rootfs/sbin tests/container/rootfs/lib* tests/container/rootfs/usr /var/lib/machines/$CONTAINER_NAME/ 2>/dev/null || true"
    
    # Start the container
    run_cmd 3 "Starting container $CONTAINER_NAME" "machinectl start \"$CONTAINER_NAME\""
    if [ $? -ne 0 ]; then
        log_phase 3 "Error: Failed to start container with machinectl start"
        run_cmd 3 "Capturing detailed startup failure logs" "machinectl status \"$CONTAINER_NAME\""
        run_cmd 3 "Checking machined logs" "journalctl -u systemd-machined.service -n 50"
        run_cmd 3 "Checking systemd-nspawn log output" "journalctl -u systemd-nspawn@$CONTAINER_NAME.service -n 50"
        run_cmd 3 "Checking importctl list" "importctl list-images"
        run_cmd 3 "Checking journal container messages" "journalctl -xb --grep=\"$CONTAINER_NAME\""
        
        # Try alternative approach if first method failed
        run_cmd 3 "Trying alternative approaches to start the container" "machinectl enable \"$CONTAINER_NAME\" 2>/dev/null"
        if [ $? -eq 0 ]; then
            run_cmd 3 "Enabled container, trying to start again" "machinectl start \"$CONTAINER_NAME\""
            if [ $? -ne 0 ]; then
                log_phase 3 "Alternative approach also failed to start container"
                run_cmd 3 "Checking final container status" "machinectl status \"$CONTAINER_NAME\""
                
                run_cmd 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
                
                # Record end time and finalize logs
                TEST_END_TIME=$(date +%s)
                TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
                finalize_logs 1 "$TEST_DURATION"
                
                return 1
            fi
        else
            log_phase 3 "Failed to enable container"
            run_cmd 3 "Checking container status" "machinectl status \"$CONTAINER_NAME\""
            
            run_cmd 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
            
            # Record end time and finalize logs
            TEST_END_TIME=$(date +%s)
            TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
            finalize_logs 1 "$TEST_DURATION"
            
            return 1
        fi
    fi
    
    # Wait for container to be fully running - disable trap during waiting
    trap - EXIT
    log_phase 3 "Waiting for container to start..."
    CONTAINER_READY=false
    for i in {1..30}; do
        if machinectl status "$CONTAINER_NAME" 2>/dev/null | grep -q "State: running"; then
            run_cmd 3 "Container is now running" "machinectl status \"$CONTAINER_NAME\""
            CONTAINER_READY=true
            break
        fi
        run_cmd 3 "Waiting attempt $i/30" "machinectl status \"$CONTAINER_NAME\""
        sleep 2
    done

    # Verify container is running
    if [ "$CONTAINER_READY" != "true" ]; then
        log_phase 3 "Error: Container failed to start properly. Check system logs."
        run_cmd 3 "Checking systemd-machined logs" "journalctl -u systemd-machined.service -n 100"
        run_cmd 3 "Final container status" "machinectl status \"$CONTAINER_NAME\""
        
        run_cmd 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_logs 1 "$TEST_DURATION"
        
        trap early_cleanup EXIT
        return 1
    fi
    
    # Container is running, reinstall the proper cleanup trap
    log_phase 3 "Container is running, proceeding with tests..."
    trap cleanup EXIT
    
    # Phase 4: Test execution
    log_phase 4 "Starting test execution phase"
    
    # Create a file to capture test output
    TEST_OUTPUT_FILE="$LOG_DIR/test_output.txt"
    > "$TEST_OUTPUT_FILE"
    
    # Run tests in the container
    log_phase 4 "Running tests in container $CONTAINER_NAME"
    
    # Execute the test runner and capture its output in a way that will definitely work
    # Use script command to capture ALL output including control characters
    if [ "$DEBUG_MODE" = "true" ]; then
        # In debug mode, show output in real-time
        run_cmd 4 "Running test-runner.sh in container" "script -q -c \"machinectl shell $CONTAINER_NAME /usr/bin/bash -c 'cd /root && PROJECT_NAME=\\\"${PROJECT_NAME:-BTRFS Subvolume Tools}\\\" exec /usr/bin/bash ./test-runner.sh'\" /dev/null | tee \"$TEST_OUTPUT_FILE\""
    else
        # In normal mode, capture output to file only
        run_cmd 4 "Running test-runner.sh in container" "script -q -c \"machinectl shell $CONTAINER_NAME /usr/bin/bash -c 'cd /root && PROJECT_NAME=\\\"${PROJECT_NAME:-BTRFS Subvolume Tools}\\\" exec /usr/bin/bash ./test-runner.sh'\" /dev/null > \"$TEST_OUTPUT_FILE\""
    fi
    TEST_RESULT=$?
    
    # Log the test result - in normal mode, just show summary info
    if [ "$DEBUG_MODE" != "true" ]; then
        log_phase 4 "Test execution complete with result: $TEST_RESULT"
        run_cmd 4 "Test summary" "head -n 10 \"$TEST_OUTPUT_FILE\""
    else
        log_phase 4 "Full test output (debug mode): $TEST_RESULT"
    fi
    
    # Phase 5: Cleanup and results
    log_phase 5 "Starting cleanup and results phase"
    
    # Capture container logs for debugging
    run_cmd 5 "Capturing container journal" "journalctl -M \"$CONTAINER_NAME\""
    
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
    echo "Test logs saved to: $LOG_DIR"
    
    return $TEST_RESULT
}

# Main function
main() {
    # Default settings
    INSTALL_MODE=true
    TEST_MODE=false
    
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
            --prefix=*)
                PREFIX="${arg#*=}"
                shift
                ;;
        esac
    done
    
    # Either install or run tests
    if [ "$TEST_MODE" = true ]; then
        if ! run_tests; then
            echo "Tests failed or encountered an error."
            exit 1
        fi
    elif [ "$INSTALL_MODE" = true ]; then
        if ! do_install "$PREFIX"; then
            echo "Installation failed."
            exit 1
        fi
    fi
}

# Run main function
main "$@"