#!/bin/bash
# Remove the set -e to prevent premature exits on command failures
# We'll handle errors explicitly instead

PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Identifier for systemd journal logging
IDENTIFIER="btrfs-subvolume-tools-installer"

# Detect available logging systems
HAS_SYSTEMD=false
HAS_SYSLOG=false

# Check for systemd-cat
if command -v systemd-cat >/dev/null 2>&1; then
    HAS_SYSTEMD=true
fi

# Check for logger (syslog)
if command -v logger >/dev/null 2>&1; then
    HAS_SYSLOG=true
fi

# Source the logging functions
if [ -f "$SCRIPT_DIR/logging.sh" ]; then
    source "$SCRIPT_DIR/logging.sh"
else
    echo "Error: logging.sh not found"
    exit 1
fi

# Define logging functions for systemd journal

# Log to system logs with appropriate priority
log_journal() {
    local priority="$1"
    local message="$2"
    
    # Log to systemd journal if available
    if [ "$HAS_SYSTEMD" = true ]; then
        echo "$message" | systemd-cat -t "$IDENTIFIER" -p "$priority"
    # Fall back to syslog if available
    elif [ "$HAS_SYSLOG" = true ]; then
        logger -t "$IDENTIFIER" -p "user.$priority" "$message"
    # If neither is available, log to a file
    else
        local log_file="/tmp/btrfs-subvolume-tools-install.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$priority] $message" >> "$log_file"
    fi
    
    # Also log to console based on priority
    case "$priority" in
        "err"|"crit"|"alert"|"emerg")
            echo "ERROR: $message" >&2
            ;;
        "warning")
            echo "WARNING: $message" >&2
            ;;
        "notice"|"info")
            echo "INFO: $message"
            ;;
        *)
            # Debug messages only shown if DEBUG is true
            if [ "$DEBUG" = "true" ]; then
                echo "DEBUG: $message"
            fi
            ;;
    esac
}

# Convenience functions for different log levels
log_error() {
    log_journal "err" "$1"
    # Also use the existing logging system if available
    if type log_phase >/dev/null 2>&1; then
        log_phase 1 "ERROR: $1"
    fi
}

log_warning() {
    log_journal "warning" "$1"
    # Also use the existing logging system if available
    if type log_phase >/dev/null 2>&1; then
        log_phase 1 "WARNING: $1"
    fi
}

log_info() {
    log_journal "info" "$1"
    # Also use the existing logging system if available
    if type log_phase >/dev/null 2>&1; then
        log_phase 1 "$1"
    fi
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        log_journal "debug" "$1"
        # Also use the existing logging system if available
        if type log_phase >/dev/null 2>&1; then
            log_phase 1 "DEBUG: $1"
        fi
    fi
}

# Display help information
show_help() {
    echo "BTRFS Subvolume Tools Installer"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help           Show this help message"
    echo "  --prefix=PATH    Install to PATH instead of /usr/local"
    echo "  --debug          Enable debug mode"
    echo ""
    echo "Installation will place files in:"
    echo "  <prefix>/bin                     - Executable scripts"
    echo "  <prefix>/share/man/man8          - Man pages"
    echo "  <prefix>/share/doc/btrfs-subvolume-tools - Documentation"
    echo ""
}

# Install the software
do_install() {
    local prefix="$1"
    
    log_info "Installing btrfs-subvolume-tools to $prefix"

    # Create directories if they don't exist
    mkdir -p "$prefix/bin"
    mkdir -p "$prefix/share/man/man8"
    mkdir -p "$prefix/share/doc/btrfs-subvolume-tools"

    # Generate man pages
    if command -v pandoc >/dev/null 2>&1; then
        log_info "Generating man pages with pandoc..."
        
        # Man page for create-subvolume
        if [ -f "doc/create-subvolume.md" ]; then
            log_debug "Processing create-subvolume.md"
            pandoc -s -t man doc/create-subvolume.md -o /tmp/create-subvolume.8
            gzip -f /tmp/create-subvolume.8
            cp /tmp/create-subvolume.8.gz "$prefix/share/man/man8/"
            rm /tmp/create-subvolume.8.gz
        else
            log_warning "doc/create-subvolume.md not found, skipping man page"
        fi
        
        # Man page for configure-snapshots
        if [ -f "doc/configure-snapshots.md" ]; then
            log_debug "Processing configure-snapshots.md"
            pandoc -s -t man doc/configure-snapshots.md -o /tmp/configure-snapshots.8
            gzip -f /tmp/configure-snapshots.8
            cp /tmp/configure-snapshots.8.gz "$prefix/share/man/man8/"
            rm /tmp/configure-snapshots.8.gz
        else
            log_warning "doc/configure-snapshots.md not found, skipping man page"
        fi
    else
        log_warning "pandoc not found, skipping man page installation"
    fi

    # Install scripts
    if [ -f "bin/create-subvolume.sh" ]; then
        log_info "Installing create-subvolume script..."
        cp bin/create-subvolume.sh "$prefix/bin/create-subvolume"
        chmod 755 "$prefix/bin/create-subvolume"
    else
        log_error "bin/create-subvolume.sh not found"
        return 1
    fi

    if [ -f "bin/configure-snapshots.sh" ]; then
        log_info "Installing configure-snapshots script..."
        cp bin/configure-snapshots.sh "$prefix/bin/configure-snapshots"
        chmod 755 "$prefix/bin/configure-snapshots"
    else
        log_error "bin/configure-snapshots.sh not found"
        return 1
    fi

    # Install documentation
    log_info "Installing documentation..."
    for doc in README.md CHANGELOG.md LICENSE; do
        if [ -f "$doc" ]; then
            cp "$doc" "$prefix/share/doc/btrfs-subvolume-tools/"
        else
            log_warning "$doc not found, skipping"
        fi
    done

    # Update man database if mandb is available
    if command -v mandb >/dev/null 2>&1; then
        log_info "Updating man database..."
        mandb >/dev/null 2>&1 || true
    fi

    log_info "Installation completed successfully to $prefix"
    log_info "You can now use:"
    log_info "  create-subvolume    - To create and configure btrfs subvolumes"
    log_info "  configure-snapshots - To set up snapper for automated snapshots"
    log_info "See the man pages for more information:"
    log_info "  man create-subvolume"
    log_info "  man configure-snapshots"
    
    return 0
}

# Main function
main() {
    # Log start of installation
    log_journal "info" "Starting BTRFS Subvolume Tools installation"
    
    # Parse command line arguments
    parse_args() {
        while [[ $# -gt 0 ]]; do
            case $1 in
                --help)
                    show_help
                    exit 0
                    ;;
                --debug)
                    export DEBUG=true
                    log_journal "info" "Debug mode enabled"
                    shift
                    ;;
                --prefix=*)
                    PREFIX="${1#*=}"
                    log_journal "info" "Installation prefix set to: $PREFIX"
                    shift
                    ;;
                *)
                    # Skip unknown arguments
                    log_journal "warning" "Unknown argument: $1"
                    shift
                    ;;
            esac
        done
    }
    
    parse_args "$@"
    
    # Run installation
    if ! do_install "$PREFIX"; then
        log_error "Installation failed."
        log_journal "err" "Installation failed"
        exit 1
    fi
    
    log_journal "info" "Installation completed successfully"
    exit 0
}

# Run main function
main "$@"