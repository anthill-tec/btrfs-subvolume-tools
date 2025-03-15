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
    echo "Running tests using systemd-nspawn..."
    
    # Check if systemd-nspawn is available
    if ! command -v systemd-nspawn >/dev/null 2>&1; then
        echo "Error: systemd-nspawn is not available. Cannot run tests."
        exit 1
    fi
    
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
            echo "Using pacman to create container..."
            mkdir -p tests/container/rootfs/{bin,lib,usr}
            pacman -Ql filesystem | grep -o '/[^ ]*' | xargs -I{} cp --parents -a {} tests/container/rootfs/ 2>/dev/null || true
            pacman -Ql bash | grep -o '/[^ ]*' | xargs -I{} cp --parents -a {} tests/container/rootfs/ 2>/dev/null || true
            pacman -Ql btrfs-progs | grep -o '/[^ ]*' | xargs -I{} cp --parents -a {} tests/container/rootfs/ 2>/dev/null || true
            pacman -Ql snapper | grep -o '/[^ ]*' | xargs -I{} cp --parents -a {} tests/container/rootfs/ 2>/dev/null || true
        else
            echo "Error: Could not create container. Please install Docker or pacman."
            exit 1
        fi
    else
        echo "Using existing container..."
    fi
    
    # Copy scripts and tests to container
	echo "Copying scripts and tests to container..."
	cp -r bin tests/container/rootfs/root/bin/
	cp -r tests/test-*.sh tests/container/rootfs/root/
	cp tests/test-runner.sh tests/container/rootfs/root/
    
    # Create test disk images
    echo "Creating test disk images..."
    mkdir -p tests/container/rootfs/root/images
    dd if=/dev/zero of=tests/container/rootfs/root/images/target-disk.img bs=1M count=500 status=none
    dd if=/dev/zero of=tests/container/rootfs/root/images/backup-disk.img bs=1M count=300 status=none
    
   # Run tests in container
   echo "Running tests..."
   systemd-nspawn --directory=tests/container/rootfs \
       --capability=all \
       --bind=/dev \
       --bind=/sys/fs/btrfs \
       /bin/bash -c "cd /root && ./test-runner.sh"
    
    TEST_RESULT=$?
    
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

