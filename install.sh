#!/bin/bash
set -e

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

# Run tests in a container
run_tests() {
    echo "Running tests in container..."
    
    # Check if we have root privileges
    if [ "$EUID" -ne 0 ]; then
        echo "Error: Tests must be run with root privileges"
        echo "Please run: sudo $0 --test"
        exit 1
    fi
    
    # Set up cleanup trap to ensure cleanup happens even on errors
    cleanup() {
        echo "Cleaning up test environment..."
        rm -rf tests/container
    }
    trap cleanup EXIT

    # Create test container
    mkdir -p tests/container/rootfs
    
    if [ ! -d tests/container/rootfs/bin ]; then
        echo "Setting up test container..."
        
        # Try different methods to create container
        if command -v docker >/dev/null 2>&1; then
            echo "Using Docker to create container..."
            docker pull archlinux:latest
            container_id=$(docker create archlinux:latest)
            docker export $container_id | tar -x -C tests/container/rootfs
            docker rm $container_id
            
            # Install required packages in the container
            echo "Installing required packages in container..."
            systemd-nspawn -D tests/container/rootfs --pipe /bin/bash -c "pacman -Sy --noconfirm btrfs-progs snapper"
        elif [ -f /etc/arch-release ] && command -v pacman >/dev/null 2>&1; then
            echo "Creating minimal container environment..."
            
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
            # Don't create /dev/console to avoid conflicts
            
            # Explicitly copy bash and its dependencies
            echo "Copying bash and essential binaries..."
            BASH_PATH=$(which bash)
            if [ -n "$BASH_PATH" ]; then
                mkdir -p tests/container/rootfs$(dirname "$BASH_PATH")
                cp "$BASH_PATH" tests/container/rootfs$(dirname "$BASH_PATH")/
                
                # Always create /bin/bash for compatibility
                mkdir -p tests/container/rootfs/bin
                if [ ! -f "tests/container/rootfs/bin/bash" ]; then
                    if [ -f "tests/container/rootfs$BASH_PATH" ]; then
                        ln -sf "$BASH_PATH" tests/container/rootfs/bin/bash
                    else
                        cp "$BASH_PATH" tests/container/rootfs/bin/
                    fi
                fi
                
                # Copy bash dependencies
                echo "Copying bash dependencies..."
                ldd "$BASH_PATH" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
                    if [ -f "$lib" ]; then
                        mkdir -p tests/container/rootfs$(dirname "$lib")
                        cp "$lib" tests/container/rootfs$(dirname "$lib")/ 2>/dev/null || true
                    fi
                done
            else
                echo "Error: bash not found"
                exit 1
            fi

            # Copy other essential binaries and their dependencies
            for cmd in sh ls mount umount mkdir cp rm btrfs mkfs.btrfs snapper findmnt grep sed awk chmod; do
                # Find the binary
                bin_path=$(which $cmd 2>/dev/null)
                if [ -n "$bin_path" ]; then
                    mkdir -p tests/container/rootfs$(dirname "$bin_path")
                    cp "$bin_path" tests/container/rootfs$(dirname "$bin_path")/ 2>/dev/null || true
        
                    # Copy dependencies
                    ldd "$bin_path" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
                        if [ -f "$lib" ]; then
                            mkdir -p tests/container/rootfs$(dirname "$lib")
                            cp "$lib" tests/container/rootfs$(dirname "$lib")/ 2>/dev/null || true
                        fi
                    done
                fi
            done
            
            # Create essential files
            echo "root:x:0:0:root:/root:/bin/bash" > tests/container/rootfs/etc/passwd
            echo "root:x:0:" > tests/container/rootfs/etc/group
            mkdir -p tests/container/rootfs/root
            
            # Create minimal snapper config directory
            mkdir -p tests/container/rootfs/etc/snapper/configs
        else
            echo "Error: Could not create container. Please install Docker or use Arch Linux."
            exit 1
        fi
    else
        echo "Using existing container..."
    fi
    
    # Copy scripts and tests to container
    echo "Copying scripts and tests to container..."
    mkdir -p tests/container/rootfs/root/bin tests/container/rootfs/root/tests
    cp -r bin/* tests/container/rootfs/root/bin/
    cp tests/*.sh tests/container/rootfs/root/
    
    # Create test disk images
    echo "Creating test disk images..."
    mkdir -p tests/container/rootfs/root/images
    dd if=/dev/zero of=tests/container/rootfs/root/images/target-disk.img bs=1M count=500 status=none
    dd if=/dev/zero of=tests/container/rootfs/root/images/backup-disk.img bs=1M count=300 status=none
    
    # Run tests directly in the container with special options to avoid console issues
    echo "Running tests..."
    systemd-nspawn --directory=tests/container/rootfs \
        --bind=/dev \
        --bind=/sys/fs/btrfs \
        --capability=all \
        --console=pipe \
        /bin/bash -c "cd /root && chmod +x ./*.sh && ./test-runner.sh"
    TEST_RESULT=$?
    
    # Cleanup
    echo "Cleaning up test environment..."
    rm -rf tests/container
    
    if [ $TEST_RESULT -eq 0 ]; then
        echo "All tests passed!"
        return 0
    else
        echo "Some tests failed."
        return $TEST_RESULT
    fi
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
        run_tests
    elif [ "$INSTALL_MODE" = true ]; then
        do_install "$PREFIX"
    fi
}

# Run main function
main "$@"

