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
            log_to_phase 5 "Terminating container $CONTAINER_NAME" "machinectl poweroff \"$CONTAINER_NAME\" 2>/dev/null || true"
            sleep 2
            log_to_phase 5 "Removing container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true"
            log_to_phase 5 "Final cleanup" "machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        fi
        rm -rf tests/container 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    # Generate unique container name
    CONTAINER_NAME="btrfs-test-$(date +%Y%m%d-%H%M%S)"
    
    # Set up logging for this test session
    LOG_DIR=$(setup_logging "$CONTAINER_NAME")
    
    # Record start time
    TEST_START_TIME=$(date +%s)
    
    # Set up early cleanup trap for script preparation phase
    trap early_cleanup EXIT
    
    # Phase 1: Pre-installation
    log_to_phase 1 "Starting pre-installation phase" 
    log_to_phase 1 "Cleaning up any existing test containers" "machinectl list | grep 'btrfs-test-'"
    
    # Clean up any existing containers with similar name (safety check)
    machinectl list | grep "btrfs-test-" | awk '{print $1}' | while read machine; do
        log_to_phase 1 "Cleaning up existing container: $machine" "machinectl terminate \"$machine\" 2>/dev/null || true"
        log_to_phase 1 "Removing container" "machinectl remove \"$machine\" 2>/dev/null || true"
    done
    
    log_to_phase 1 "Creating test directory structure" "mkdir -p tests/container/rootfs"
    
    # Phase 2: Tool setup
    log_to_phase 2 "Starting tool setup phase"
    
    if [ ! -d tests/container/rootfs/bin ]; then
        log_to_phase 2 "Setting up test container..."
        
        # Check for pacstrap and install if missing
        if ! command -v pacstrap >/dev/null 2>&1; then
            log_to_phase 2 "Pacstrap not found. Attempting to install it..."
            
            if command -v yay >/dev/null 2>&1; then
                log_to_phase 2 "Installing arch-install-scripts using yay" "yay -S --noconfirm arch-install-scripts"
            elif command -v pacman >/dev/null 2>&1; then
                log_to_phase 2 "Installing arch-install-scripts using pacman" "pacman -S --noconfirm arch-install-scripts"
            else
                log_to_phase 2 "Warning: Could not install pacstrap. Neither yay nor pacman found."
            fi
        fi
        
        if command -v pacstrap >/dev/null 2>&1; then
            log_to_phase 2 "Creating minimal Arch container using pacstrap" "pacstrap -c -d tests/container/rootfs base systemd bash btrfs-progs snapper"
        elif [ -f /etc/arch-release ] && command -v pacman >/dev/null 2>&1; then
            log_to_phase 2 "Creating minimal container environment manually"
            
            # Create basic directory structure
            log_to_phase 2 "Creating basic directory structure" "mkdir -p tests/container/rootfs/{bin,sbin,lib,lib64,usr/{bin,sbin,lib},etc,var,dev,sys,proc,run,tmp}"
            log_to_phase 2 "Setting tmp permissions" "chmod 1777 tests/container/rootfs/tmp"
            
            # Prepare /dev for systemd-nspawn
            log_to_phase 2 "Preparing /dev for systemd-nspawn" "mkdir -p tests/container/rootfs/dev/{pts,shm}"
            
            # Add essential device nodes 
            log_to_phase 2 "Adding essential device nodes" "mknod -m 666 tests/container/rootfs/dev/null c 1 3"
            log_to_phase 2 "Adding zero device" "mknod -m 666 tests/container/rootfs/dev/zero c 1 5"
            log_to_phase 2 "Adding random device" "mknod -m 666 tests/container/rootfs/dev/random c 1 8"
            log_to_phase 2 "Adding urandom device" "mknod -m 666 tests/container/rootfs/dev/urandom c 1 9"
            
            # Copy required executables and libraries
            log_to_phase 2 "Copying required executables and libraries"
            for pkg in coreutils bash util-linux systemd btrfs-progs snapper; do
                log_to_phase 2 "Processing $pkg package" "pacman -Ql $pkg 2>/dev/null | grep -v '/$' | grep -E '/(s?bin|lib)/' | wc -l"
                pacman -Ql $pkg 2>/dev/null | grep -v '/$' | grep -E '/(s?bin|lib)/' | awk '{print $2}' | while read file; do
                    if [ -f "$file" ] && [ -x "$file" ]; then
                        log_to_phase 2 "Copying $file and dependencies" "copy_with_deps \"$file\" \"tests/container/rootfs\""
                    fi
                done
            done
            
            # Create essential files
            log_to_phase 2 "Creating essential files" "echo \"root:x:0:0:root:/root:/bin/bash\" > tests/container/rootfs/etc/passwd"
            log_to_phase 2 "Creating root group" "echo \"root:x:0:\" > tests/container/rootfs/etc/group"
            log_to_phase 2 "Creating root home directory" "mkdir -p tests/container/rootfs/root"
            
            # Create minimal snapper config directory
            log_to_phase 2 "Creating snapper config directory" "mkdir -p tests/container/rootfs/etc/snapper/configs"
        else
            log_to_phase 2 "Error: This script requires Arch Linux with either pacstrap or pacman for container creation."
            log_to_phase 2 "Please install Arch Linux or modify this script for your distribution."
            
            # Record end time and finalize logs
            TEST_END_TIME=$(date +%s)
            TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
            finalize_log_summary 1 "$TEST_DURATION"
            
            return 1
        fi
    else
        log_to_phase 2 "Using existing container..."
    fi
    
    # Copy bin scripts to container
    log_to_phase 2 "Copying bin scripts to container" "mkdir -p tests/container/rootfs/root/bin"
    log_to_phase 2 "Copying scripts" "cp -rv bin/* tests/container/rootfs/root/bin/"
    
    # Prepare test scripts for container environment
    log_to_phase 2 "Preparing test scripts for container environment" "cat tests/test-runner.sh | sed 's|/bin/bash|/usr/bin/bash|g' > /tmp/test-runner.sh.tmp"
    
    # Copy the test-runner script
    log_to_phase 2 "Copying test-runner script" "cp /tmp/test-runner.sh.tmp tests/container/rootfs/root/test-runner.sh && chmod +x tests/container/rootfs/root/test-runner.sh"
    
    # Find and copy all test scripts (except test-runner.sh itself)
    log_to_phase 2 "Copying test scripts"
    TEST_RUNNER_NAME=$(basename "$(find tests -name "test-runner.sh" | head -n 1)")
    find tests -name "test-*.sh" ! -name "$TEST_RUNNER_NAME" | while read script; do
        log_to_phase 2 "Copying: $script" "cp \"$script\" tests/container/rootfs/root/ && chmod +x tests/container/rootfs/root/$(basename \"$script\")"
    done
    
    # Create test disk images
    log_to_phase 2 "Creating test disk images" "mkdir -p tests/container/rootfs/images"
    log_to_phase 2 "Creating target disk image" "dd if=/dev/zero of=tests/container/rootfs/images/target-disk.img bs=1M count=500 status=none"
    log_to_phase 2 "Creating backup disk image" "dd if=/dev/zero of=tests/container/rootfs/images/backup-disk.img bs=1M count=300 status=none"
    
    # Phase 3: Test configuration
    log_to_phase 3 "Starting test configuration phase"
    
    # Import container filesystem
    log_to_phase 3 "Importing container filesystem as $CONTAINER_NAME" "machinectl import-fs tests/container/rootfs \"$CONTAINER_NAME\""
    if [ $? -ne 0 ]; then
        log_to_phase 3 "Error: Failed to import container filesystem" "machinectl status \"$CONTAINER_NAME\""
        log_to_phase 3 "Checking machined logs" "journalctl -u systemd-machined.service -n 50"
        log_to_phase 3 "Checking import service logs" "journalctl -b -u importctl.service -n 50"
        
        # Clean up any partial container
        log_to_phase 3 "Cleaning up partial container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_log_summary 1 "$TEST_DURATION"
        
        return 1
    fi
    
    # Verify container structure
    log_to_phase 3 "Verifying container structure" "find tests/container/rootfs -type d | sort | head -n 20"
    log_to_phase 3 "Checking container files" "find tests/container/rootfs -type f | grep -v 'img$' | sort | head -n 20"
    
    # Check for critical files
    for file in /etc/os-release /etc/machine-id; do
        if [ ! -f "tests/container/rootfs$file" ]; then
            log_to_phase 3 "Warning: Critical file missing: $file"
            
            # Create basic placeholder files
            case "$file" in
                "/etc/os-release")
                    log_to_phase 3 "Creating placeholder os-release file" "mkdir -p \"tests/container/rootfs/etc\" && echo 'NAME=\"Minimal Container\"' > \"tests/container/rootfs/etc/os-release\" && echo 'ID=minimal' >> \"tests/container/rootfs/etc/os-release\" && echo 'VERSION_ID=\"1.0\"' >> \"tests/container/rootfs/etc/os-release\""
                    ;;
                "/etc/machine-id")
                    if command -v uuidgen &> /dev/null; then
                        log_to_phase 3 "Creating machine-id using uuidgen" "mkdir -p \"tests/container/rootfs/etc\" && uuidgen | tr -d '-' > \"tests/container/rootfs/etc/machine-id\""
                    else
                        log_to_phase 3 "Creating machine-id using date+sha256" "mkdir -p \"tests/container/rootfs/etc\" && echo \"$(date +%s%N | sha256sum | head -c 32)\" > \"tests/container/rootfs/etc/machine-id\""
                    fi
                    ;;
            esac
        fi
    done
    
    # Start the container
    log_to_phase 3 "Starting container $CONTAINER_NAME" "machinectl start \"$CONTAINER_NAME\""
    if [ $? -ne 0 ]; then
        log_to_phase 3 "Error: Failed to start container with machinectl start"
        log_to_phase 3 "Capturing detailed startup failure logs" "machinectl status \"$CONTAINER_NAME\""
        log_to_phase 3 "Checking machined logs" "journalctl -u systemd-machined.service -n 50"
        log_to_phase 3 "Checking importctl list" "importctl list-images"
        log_to_phase 3 "Checking journal container messages" "journalctl -xb --grep=\"$CONTAINER_NAME\""
        
        # Try alternative approach if first method failed
        log_to_phase 3 "Trying alternative approaches to start the container" "machinectl enable \"$CONTAINER_NAME\" 2>/dev/null"
        if [ $? -eq 0 ]; then
            log_to_phase 3 "Enabled container, trying to start again" "machinectl start \"$CONTAINER_NAME\""
            if [ $? -ne 0 ]; then
                log_to_phase 3 "Alternative approach also failed to start container" "machinectl status \"$CONTAINER_NAME\""
                
                log_to_phase 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
                
                # Record end time and finalize logs
                TEST_END_TIME=$(date +%s)
                TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
                finalize_log_summary 1 "$TEST_DURATION"
                
                return 1
            fi
        else
            log_to_phase 3 "Failed to enable container" "machinectl status \"$CONTAINER_NAME\""
            
            log_to_phase 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
            
            # Record end time and finalize logs
            TEST_END_TIME=$(date +%s)
            TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
            finalize_log_summary 1 "$TEST_DURATION"
            
            return 1
        fi
    fi
    
    # Wait for container to be fully running - disable trap during waiting
    trap - EXIT
    log_to_phase 3 "Waiting for container to start..."
    CONTAINER_READY=false
    for i in {1..30}; do
        if machinectl status "$CONTAINER_NAME" 2>/dev/null | grep -q "State: running"; then
            log_to_phase 3 "Container is now running" "machinectl status \"$CONTAINER_NAME\""
            CONTAINER_READY=true
            break
        fi
        log_to_phase 3 "Waiting attempt $i/30" "machinectl status \"$CONTAINER_NAME\""
        sleep 2
    done

    # Verify container is running
    if [ "$CONTAINER_READY" != "true" ]; then
        log_to_phase 3 "Error: Container failed to start properly. Check system logs." "journalctl -u systemd-machined.service -n 100"
        log_to_phase 3 "Final container status" "machinectl status \"$CONTAINER_NAME\""
        
        log_to_phase 3 "Cleaning up failed container" "machinectl terminate \"$CONTAINER_NAME\" 2>/dev/null || true && machinectl remove \"$CONTAINER_NAME\" 2>/dev/null || true"
        
        # Record end time and finalize logs
        TEST_END_TIME=$(date +%s)
        TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
        finalize_log_summary 1 "$TEST_DURATION"
        
        trap early_cleanup EXIT
        return 1
    fi
    
    # Container is running, reinstall the proper cleanup trap
    log_to_phase 3 "Container is running, proceeding with tests..."
    trap cleanup EXIT
    
    # Phase 4: Test execution
    log_to_phase 4 "Starting test execution phase"
    
    # Create a file to capture test output
    TEST_OUTPUT_FILE="$LOG_DIR/test_output.txt"
    > "$TEST_OUTPUT_FILE"
    
    # Run tests in the container
    log_to_phase 4 "Running tests in container $CONTAINER_NAME"
    
    # Execute the test runner and capture its output
    machinectl shell "$CONTAINER_NAME" /usr/bin/bash -c "cd /root && PROJECT_NAME=\"${PROJECT_NAME:-BTRFS Subvolume Tools}\" exec /usr/bin/bash ./test-runner.sh" > "$TEST_OUTPUT_FILE" 2>&1
    TEST_RESULT=$?
    
    # Log the test output
    log_to_phase 4 "Test execution complete with result: $TEST_RESULT" "cat \"$TEST_OUTPUT_FILE\""
    
    # Phase 5: Cleanup and results
    log_to_phase 5 "Starting cleanup and results phase"
    
    # Capture container logs for debugging
    log_to_phase 5 "Capturing container journal" "journalctl -M \"$CONTAINER_NAME\""
    
    # Record end time
    TEST_END_TIME=$(date +%s)
    TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
    
    # Finalize logs
    log_to_phase 5 "Finalizing test results"
    if [ $TEST_RESULT -eq 0 ]; then
        log_to_phase 5 "All tests passed!"
    else
        log_to_phase 5 "Some tests failed. Check logs for details."
    fi
    
    # Add final summary to the log
    finalize_log_summary $TEST_RESULT "$TEST_DURATION"
    
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