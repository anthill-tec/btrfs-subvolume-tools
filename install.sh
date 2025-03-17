#!/bin/bash
# Remove the set -e to prevent premature exits on command failures
# We'll handle errors explicitly instead

PREFIX="${PREFIX:-/usr/local}"

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
    
    # Clean up function declarations - to be used by traps
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
            echo "Terminating container $CONTAINER_NAME..."
            machinectl poweroff "$CONTAINER_NAME" 2>/dev/null || true
            sleep 2
            machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
            machinectl remove "$CONTAINER_NAME" 2>/dev/null || true
        fi
        rm -rf tests/container 2>/dev/null || true
        rm -f /tmp/test-*.sh.tmp 2>/dev/null || true
    }
    
    # Set up early cleanup trap for script preparation phase
    trap early_cleanup EXIT
    
    # Create test container directory
    mkdir -p tests/container/rootfs
    
    if [ ! -d tests/container/rootfs/bin ]; then
        echo "Setting up test container..."
        
        # Check for pacstrap and install if missing
        if ! command -v pacstrap >/dev/null 2>&1; then
            echo "Pacstrap not found. Attempting to install it..."
            
            if command -v yay >/dev/null 2>&1; then
                echo "Installing arch-install-scripts using yay..."
                yay -S --noconfirm arch-install-scripts
            elif command -v pacman >/dev/null 2>&1; then
                echo "Installing arch-install-scripts using pacman..."
                pacman -S --noconfirm arch-install-scripts
            else
                echo "Warning: Could not install pacstrap. Neither yay nor pacman found."
            fi
        fi
        
        if command -v pacstrap >/dev/null 2>&1; then
            echo "Creating minimal Arch container using pacstrap..."
            # Create basic directory structure first
            mkdir -p tests/container/rootfs
            # Use pacstrap to create a minimal but complete Arch system
            pacstrap -c -d tests/container/rootfs base systemd bash btrfs-progs snapper
        elif [ -f /etc/arch-release ] && command -v pacman >/dev/null 2>&1; then
            echo "Pacstrap not found. Creating minimal container environment manually..."
            # Fallback to manual setup if pacstrap isn't available
            # Create basic directory structure
            mkdir -p tests/container/rootfs/{bin,sbin,lib,lib64,usr/{bin,sbin,lib},etc,var,dev,sys,proc,run,tmp}
            chmod 1777 tests/container/rootfs/tmp
            
            # Prepare /dev for systemd-nspawn
            mkdir -p tests/container/rootfs/dev/{pts,shm}
            # Add essential device nodes 
            mknod -m 666 tests/container/rootfs/dev/null c 1 3
            mknod -m 666 tests/container/rootfs/dev/zero c 1 5
            mknod -m 666 tests/container/rootfs/dev/random c 1 8
            mknod -m 666 tests/container/rootfs/dev/urandom c 1 9
            
            # Copy required executables and libraries
            echo "Copying required executables and libraries..."
            for pkg in coreutils bash util-linux systemd btrfs-progs snapper; do
                echo "Processing $pkg package..."
                pacman -Ql $pkg 2>/dev/null | grep -v '/$' | grep -E '/(s?bin|lib)/' | awk '{print $2}' | while read file; do
                    if [ -f "$file" ] && [ -x "$file" ]; then
                        copy_with_deps "$file" "tests/container/rootfs"
                    fi
                done
            done
            
            # Copy critical libraries that might not be picked up
            echo "Copying additional critical libraries..."
            for lib in $(ldconfig -p | grep -E 'libreadline|libncurses|libtinfo' | awk '{print $4}'); do
                if [ -f "$lib" ]; then
                    copy_with_deps "$lib" "tests/container/rootfs"
                fi
            done
            
            # Also copy ld-linux (dynamic linker)
            for lib in /lib/ld-linux*.so* /lib64/ld-linux*.so* /usr/lib/ld-linux*.so*; do
                if [ -f "$lib" ]; then
                    dir=$(dirname "$lib")
                    mkdir -p "tests/container/rootfs$dir"
                    cp "$lib" "tests/container/rootfs$dir/" 2>/dev/null || true
                fi
            done
            
            # Create essential files
            echo "root:x:0:0:root:/root:/bin/bash" > tests/container/rootfs/etc/passwd
            echo "root:x:0:" > tests/container/rootfs/etc/group
            mkdir -p tests/container/rootfs/root
            
            # Create minimal snapper config directory
            mkdir -p tests/container/rootfs/etc/snapper/configs
        else
            echo "Error: This script requires Arch Linux with either pacstrap or pacman for container creation."
            echo "Please install Arch Linux or modify this script for your distribution."
            exit 1
        fi
    else
        echo "Using existing container..."
    fi
    
    # Copy bin scripts to container
    echo "Copying bin scripts..."
    mkdir -p tests/container/rootfs/root/bin
    cp -rv bin/* tests/container/rootfs/root/bin/
    
    # Prepare test scripts for container environment
    echo "Preparing test scripts for container environment..."

    # Create modified test-runner.sh
    cat tests/test-runner.sh | sed 's|/bin/bash|/usr/bin/bash|g' > /tmp/test-runner.sh.tmp
    
    # Copy the test-runner script
    echo "Copying test-runner script..."
    mkdir -p tests/container/rootfs/root
    cp /tmp/test-runner.sh.tmp tests/container/rootfs/root/test-runner.sh
    chmod +x tests/container/rootfs/root/test-runner.sh
    
    # Find and copy all test scripts (except test-runner.sh itself)
    echo "Copying test scripts..."
    TEST_RUNNER_NAME=$(basename "$(find tests -name "test-runner.sh" | head -n 1)")
    find tests -name "test-*.sh" ! -name "$TEST_RUNNER_NAME" | while read script; do
        echo "Copying: $script"
        cp "$script" tests/container/rootfs/root/
        chmod +x tests/container/rootfs/root/$(basename "$script")
    done
    
    # Create test disk images
    echo "Creating test disk images..."
    mkdir -p tests/container/rootfs/images
    dd if=/dev/zero of=tests/container/rootfs/images/target-disk.img bs=1M count=500 status=none
    dd if=/dev/zero of=tests/container/rootfs/images/backup-disk.img bs=1M count=300 status=none

    # Generate unique container name
    CONTAINER_NAME="btrfs-test-$(date +%Y%m%d-%H%M%S)"
    
    # Set up log directory structure for this container session
    LOG_BASE_DIR="tests/logs"
    LOG_SESSION_DIR="$LOG_BASE_DIR/$CONTAINER_NAME"
    mkdir -p "$LOG_SESSION_DIR"
    
    # Function to create numbered log files
    log_command() {
        local seq_num="$1"
        local command_name="$2"
        local command="$3"
        
        echo "Logging command '$command_name' (step $seq_num)..."
        $command > "$LOG_SESSION_DIR/${seq_num}_${command_name}.log" 2>&1 || true
    }
    
    # Clean up any existing container with similar name (safety check)
    machinectl list | grep "btrfs-test-" | awk '{print $1}' | while read machine; do
        echo "Cleaning up existing container: $machine"
        machinectl terminate "$machine" 2>/dev/null || true
        machinectl remove "$machine" 2>/dev/null || true
    done
    
    # Import container filesystem
    echo "Importing container filesystem as $CONTAINER_NAME..."
    if ! machinectl import-fs tests/container/rootfs "$CONTAINER_NAME"; then
        echo "Error: Failed to import container filesystem"
        log_command "01" "import_failure" "machinectl status $CONTAINER_NAME"
        log_command "02" "machined_log" "journalctl -u systemd-machined.service -n 50"
        log_command "03" "import_service_log" "journalctl -b -u importctl.service -n 50"
        
        # Clean up any partial container
        machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
        machinectl remove "$CONTAINER_NAME" 2>/dev/null || true
        return 1
    fi
    
    # Debugging: Verify container structure
    echo "Verifying container structure..."
    log_command "04" "container_dirs" "find tests/container/rootfs -type d | sort"
    log_command "05" "container_files" "find tests/container/rootfs -type f | grep -v 'img$' | sort | head -n 100"
    
    # Check for critical files
    for file in /etc/os-release /etc/machine-id; do
        if [ ! -f "tests/container/rootfs$file" ]; then
            echo "Warning: Critical file missing: $file"
            log_command "06" "missing_file_${file//\//_}" "echo 'File $file is missing from container'"
            
            # Create basic placeholder files
            case "$file" in
                "/etc/os-release")
                    mkdir -p "tests/container/rootfs/etc"
                    echo 'NAME="Minimal Container"' > "tests/container/rootfs/etc/os-release"
                    echo 'ID=minimal' >> "tests/container/rootfs/etc/os-release"
                    echo 'VERSION_ID="1.0"' >> "tests/container/rootfs/etc/os-release"
                    
                    log_command "07" "created_os_release" "cat tests/container/rootfs/etc/os-release"
                    ;;
                "/etc/machine-id")
                    mkdir -p "tests/container/rootfs/etc"
                    if command -v uuidgen &> /dev/null; then
                        echo "$(uuidgen | tr -d '-')" > "tests/container/rootfs/etc/machine-id"
                    else
                        echo "$(date +%s%N | sha256sum | head -c 32)" > "tests/container/rootfs/etc/machine-id"
                    fi
                    
                    log_command "08" "created_machine_id" "cat tests/container/rootfs/etc/machine-id"
                    ;;
            esac
        fi
    done
    
    # Start the container
    echo "Starting container $CONTAINER_NAME..."
    if ! machinectl start "$CONTAINER_NAME"; then
        echo "Error: Failed to start container with machinectl start"
        
        # Capture detailed logs about the failure
        echo "Capturing detailed startup failure logs..."
        log_command "09" "status_after_start_failure" "machinectl status $CONTAINER_NAME"
        log_command "10" "machined_log_after_start" "journalctl -u systemd-machined.service -n 50"
        log_command "11" "importctl_list" "importctl list-images" 
        log_command "12" "journal_container_messages" "journalctl -xb --grep=\"$CONTAINER_NAME\""
        
        # Try alternative approach if first method failed
        echo "Trying alternative approaches to start the container..."
        if machinectl enable "$CONTAINER_NAME" 2>/dev/null; then
            log_command "13" "enable_container" "echo 'Container enabled'"
            
            echo "Enabled container, trying to start again..."
            if machinectl start "$CONTAINER_NAME"; then
                log_command "14" "start_after_enable_success" "echo 'Container started successfully after enable'"
                echo "Container started successfully with alternative approach!"
            else
                log_command "15" "start_after_enable_failure" "echo 'Container failed to start after enable'"
                log_command "16" "final_status" "machinectl status $CONTAINER_NAME"
                
                echo "Alternative approach also failed to start container"
                machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
                machinectl remove "$CONTAINER_NAME" 2>/dev/null || true
                echo "Check logs in $LOG_SESSION_DIR for details on the failure"
                return 1
            fi
        else
            log_command "13" "enable_container_failure" "echo 'Failed to enable container'"
            log_command "14" "final_status" "machinectl status $CONTAINER_NAME"
            
            machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
            machinectl remove "$CONTAINER_NAME" 2>/dev/null || true
            echo "Check logs in $LOG_SESSION_DIR for details on the failure"
            return 1
        fi
    else
        log_command "09" "start_success" "machinectl status $CONTAINER_NAME"
    fi
    
    # Wait for container to be fully running - disable trap during waiting
    trap - EXIT
    echo "Waiting for container to start..."
    CONTAINER_READY=false
    for i in {1..30}; do
        log_command "15" "status_during_wait_${i}" "machinectl status $CONTAINER_NAME"
        
        if machinectl status "$CONTAINER_NAME" 2>/dev/null | grep -q "State: running"; then
            log_command "16" "container_running" "echo 'Container is now running'"
            CONTAINER_READY=true
            break
        fi
        echo "Waiting... ($i/30)"
        sleep 2
    done

    # Verify container is running
    if [ "$CONTAINER_READY" != "true" ]; then
        echo "Error: Container failed to start properly. Check system logs."
        log_command "17" "container_start_timeout" "echo 'Container did not reach running state after 30 attempts'"
        log_command "18" "final_machined_log" "journalctl -u systemd-machined.service -n 100"
        log_command "19" "final_container_status" "machinectl status $CONTAINER_NAME"
        
        machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
        machinectl remove "$CONTAINER_NAME" 2>/dev/null || true
        trap early_cleanup EXIT
        return 1
    fi
    
    # Container is running, reinstall the proper cleanup trap
    echo "Container is running, proceeding with tests..."
    log_command "17" "container_ready" "machinectl status $CONTAINER_NAME"
    trap cleanup EXIT
    
    # Run tests in the container
    echo "Running tests in container $CONTAINER_NAME..."
    log_command "20" "start_tests" "echo 'Beginning test execution'"
    
    if ! machinectl shell "$CONTAINER_NAME" /usr/bin/bash -c "cd /root && PROJECT_NAME=\"${PROJECT_NAME:-BTRFS Subvolume Tools}\" exec /usr/bin/bash ./test-runner.sh"; then
        log_command "21" "tests_failed" "echo 'Test execution failed'"
        TEST_RESULT=1
    else
        log_command "21" "tests_succeeded" "echo 'Test execution succeeded'"
        TEST_RESULT=0
    fi
    
    # Capture logs for debugging
    echo "Capturing container logs..."
    log_command "22" "container_journal" "journalctl -M \"$CONTAINER_NAME\""
    
    # Create a summary file
    echo "Test execution completed with result code: $TEST_RESULT" > "$LOG_SESSION_DIR/summary.log"
    echo "Container name: $CONTAINER_NAME" >> "$LOG_SESSION_DIR/summary.log"
    echo "Timestamp: $(date)" >> "$LOG_SESSION_DIR/summary.log"
    
    # Show test results
    if [ $TEST_RESULT -eq 0 ]; then
        echo "All tests passed!"
        echo "Test logs saved to: $LOG_SESSION_DIR"
    else
        echo "Some tests failed. Check logs in $LOG_SESSION_DIR"
    fi
    
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