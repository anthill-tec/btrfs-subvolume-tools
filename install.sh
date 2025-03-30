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

# Detect Linux distribution
detect_distribution() {
    # Initialize with unknown values
    DISTRO_NAME="Unknown"
    DISTRO_ID="unknown"
    DISTRO_VERSION=""
    DISTRO_BASE=""
    
    # First check for os-release which most modern distros have
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME="$NAME"
        DISTRO_ID="$ID"
        DISTRO_VERSION="$VERSION_ID"
        
        # Check for ID_LIKE to determine base distribution
        if [ -n "$ID_LIKE" ]; then
            # Check if it's Arch-based
            if [[ "$ID_LIKE" == *"arch"* ]]; then
                DISTRO_BASE="arch"
            # Check if it's Debian-based
            elif [[ "$ID_LIKE" == *"debian"* ]]; then
                DISTRO_BASE="debian"
            fi
        fi
    fi
    
    # If we couldn't determine the base, try more specific checks
    if [ -z "$DISTRO_BASE" ]; then
        # Check for Arch Linux and derivatives
        if [ -f /etc/arch-release ] || command -v pacman >/dev/null 2>&1; then
            DISTRO_BASE="arch"
            # If we didn't get the name from os-release, set it here
            if [ "$DISTRO_NAME" = "Unknown" ]; then
                DISTRO_NAME="Arch Linux"
                DISTRO_ID="arch"
            fi
        # Check for Debian and derivatives
        elif [ -f /etc/debian_version ]; then
            DISTRO_BASE="debian"
            if [ "$DISTRO_NAME" = "Unknown" ]; then
                DISTRO_NAME="Debian"
                DISTRO_ID="debian"
                DISTRO_VERSION=$(cat /etc/debian_version)
            fi
        fi
    fi
    
    # Log the detected distribution
    if [ "$DEBUG" = "true" ]; then
        echo "Detected distribution: $DISTRO_NAME ($DISTRO_ID) version $DISTRO_VERSION"
        echo "Base distribution: $DISTRO_BASE"
    fi
    
    return 0
}

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
    echo "  --debug          Enable debug mode"
    echo "  --prefix=PATH    Install to PATH instead of /usr/local"
    echo "  --package        Create a package for your distribution instead of installing"
    echo "  --create-pkgfiles Generate packaging files for your distribution"
    echo ""
    echo "Installation will place files in:"
    echo "  <prefix>/bin                     - Executable scripts"
    echo "  <prefix>/share/man/man8          - Man pages"
    echo "  <prefix>/share/doc/btrfs-subvolume-tools - Documentation"
    echo ""
}

# Suggest native packaging based on distribution
suggest_native_packaging() {
    detect_distribution
    
    echo ""
    echo "==============================================================="
    echo "  Distribution detected: $DISTRO_NAME"
    if [ "$DISTRO_BASE" != "$DISTRO_ID" ] && [ -n "$DISTRO_BASE" ]; then
        echo "  Base distribution: $DISTRO_BASE"
    fi
    echo "==============================================================="
    echo ""
    
    case "$DISTRO_BASE" in
        arch)
            echo "For Arch-based distributions, you can use the PKGBUILD:"
            echo ""
            echo "  # Option 1: Use the Makefile target (recommended)"
            echo "  make pkg-arch"
            echo ""
            echo "  # Option 2: Build manually"
            echo "  cd packaging/arch"
            echo "  makepkg -si"
            echo ""
            echo "This will create and install a proper Arch package."
            echo ""
            echo "Dependencies: bash, btrfs-progs, snapper"
            echo "Optional: pandoc (for man page generation)"
            ;;
        debian)
            echo "For Debian-based distributions, you can build a .deb package:"
            echo ""
            echo "  # Option 1: Use the Makefile target (recommended)"
            echo "  make pkg-deb"
            echo ""
            echo "  # Option 2: Build manually"
            echo "  cd packaging/debian"
            echo "  dpkg-buildpackage -us -uc -b"
            echo "  sudo dpkg -i ../btrfs-subvolume-tools_*.deb"
            echo ""
            echo "This will create and install a proper Debian package."
            echo ""
            echo "Dependencies: bash, btrfs-progs, snapper"
            echo "Build-Dependencies: debhelper (>= 10), pandoc"
            ;;
        *)
            echo "Your distribution ($DISTRO_NAME) doesn't have specific"
            echo "packaging instructions. Using the generic installer."
            ;;
    esac
    
    echo ""
    echo "To continue with the generic installation, press Enter."
    echo "To exit and use the distribution-specific method, press Ctrl+C."
    echo ""
    read -p "Press Enter to continue..."
}

# Create packaging files for the detected distribution
create_packaging_files() {
    detect_distribution
    
    log_info "Creating packaging files for $DISTRO_NAME (base: $DISTRO_BASE)"
    
    # Create packaging directory structure
    mkdir -p packaging/arch
    mkdir -p packaging/debian
    
    # Get version from Makefile if possible
    VERSION="1.0.0"
    if grep -q "^VERSION" Makefile; then
        VERSION=$(grep "^VERSION" Makefile | cut -d'=' -f2 | tr -d ' ')
    fi
    
    # Create Arch Linux PKGBUILD
    cat > packaging/arch/PKGBUILD << EOF
# Maintainer: Your Name <your.email@example.com>
pkgname=btrfs-subvolume-tools
pkgver=$VERSION
pkgrel=1
pkgdesc="Tools for managing BTRFS subvolumes and snapshots"
arch=('any')
url="https://github.com/yourusername/btrfs-subvolume-tools"
license=('MIT')
depends=('bash' 'btrfs-progs' 'snapper')
makedepends=('pandoc')
backup=('etc/btrfs-subvolume-tools/config')
source=("\$pkgname-\$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
  cd "\$srcdir/\$pkgname-\$pkgver"
  
  # Install binaries
  install -Dm755 bin/create-subvolume.sh "\$pkgdir/usr/bin/create-subvolume"
  install -Dm755 bin/configure-snapshots.sh "\$pkgdir/usr/bin/configure-snapshots"
  
  # Install man pages
  install -Dm644 doc/create-subvolume.8.gz "\$pkgdir/usr/share/man/man8/create-subvolume.8.gz"
  install -Dm644 doc/configure-snapshots.8.gz "\$pkgdir/usr/share/man/man8/configure-snapshots.8.gz"
  
  # Install documentation
  install -Dm644 README.md "\$pkgdir/usr/share/doc/\$pkgname/README.md"
  install -Dm644 CHANGELOG.md "\$pkgdir/usr/share/doc/\$pkgname/CHANGELOG.md"
  install -Dm644 LICENSE "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE"
  
  # Create default config directory
  install -dm755 "\$pkgdir/etc/\$pkgname"
}
EOF
    
    # Create Debian control file
    cat > packaging/debian/control << EOF
Source: btrfs-subvolume-tools
Section: admin
Priority: optional
Maintainer: Your Name <your.email@example.com>
Build-Depends: debhelper (>= 10), pandoc
Standards-Version: 4.5.0
Homepage: https://github.com/yourusername/btrfs-subvolume-tools
Vcs-Browser: https://github.com/yourusername/btrfs-subvolume-tools
Vcs-Git: https://github.com/yourusername/btrfs-subvolume-tools.git

Package: btrfs-subvolume-tools
Architecture: all
Depends: ${misc:Depends}, bash, btrfs-progs, snapper
Description: Tools for managing BTRFS subvolumes and snapshots
 A collection of scripts to create and manage BTRFS subvolumes
 and configure automated snapshots using snapper.
 .
 This package provides utilities to:
  * Create and configure BTRFS subvolumes
  * Set up snapper for automated snapshots
EOF
    
    # Create Debian rules file
    cat > packaging/debian/rules << EOF
#!/usr/bin/make -f
%:
	dh \$@

override_dh_auto_install:
	install -Dm755 bin/create-subvolume.sh \$(CURDIR)/debian/btrfs-subvolume-tools/usr/bin/create-subvolume
	install -Dm755 bin/configure-snapshots.sh \$(CURDIR)/debian/btrfs-subvolume-tools/usr/bin/configure-snapshots
	install -Dm644 doc/create-subvolume.8.gz \$(CURDIR)/debian/btrfs-subvolume-tools/usr/share/man/man8/create-subvolume.8.gz
	install -Dm644 doc/configure-snapshots.8.gz \$(CURDIR)/debian/btrfs-subvolume-tools/usr/share/man/man8/configure-snapshots.8.gz
	install -Dm644 README.md \$(CURDIR)/debian/btrfs-subvolume-tools/usr/share/doc/btrfs-subvolume-tools/README.md
	install -Dm644 CHANGELOG.md \$(CURDIR)/debian/btrfs-subvolume-tools/usr/share/doc/btrfs-subvolume-tools/CHANGELOG.md
	install -Dm644 LICENSE \$(CURDIR)/debian/btrfs-subvolume-tools/usr/share/doc/btrfs-subvolume-tools/copyright
	install -dm755 \$(CURDIR)/debian/btrfs-subvolume-tools/etc/btrfs-subvolume-tools
EOF
    
    # Create Debian changelog
    cat > packaging/debian/changelog << EOF
btrfs-subvolume-tools ($VERSION-1) unstable; urgency=medium

  * Initial release.

 -- Your Name <your.email@example.com>  Sun, 30 Mar 2025 08:00:00 +0530
EOF
    
    # Create Debian compat file
    echo "10" > packaging/debian/compat
    
    # Make rules file executable
    chmod +x packaging/debian/rules
    
    log_info "Packaging files created successfully in packaging/ directory"
    log_info "You may need to customize these files for your specific needs"
    
    echo ""
    echo "==============================================================="
    echo "  Packaging files created for $DISTRO_NAME (base: $DISTRO_BASE)"
    echo "==============================================================="
    echo ""
    echo "Files created:"
    echo "  - packaging/arch/PKGBUILD"
    echo "  - packaging/debian/control"
    echo "  - packaging/debian/rules"
    echo "  - packaging/debian/changelog"
    echo "  - packaging/debian/compat"
    echo ""
    echo "You may need to customize these files before building packages."
    echo "Remember to update your email and GitHub repository information."
    echo ""
}

# Install the software
do_install() {
    local prefix="$1"
    local destdir="${DESTDIR:-}"
    local install_root="${destdir}${prefix}"
    
    log_info "Installing btrfs-subvolume-tools to ${install_root}"

    # Create directories if they don't exist
    mkdir -p "${install_root}/bin"
    mkdir -p "${install_root}/share/man/man8"
    mkdir -p "${install_root}/share/doc/btrfs-subvolume-tools"
    mkdir -p "${install_root}/etc/btrfs-subvolume-tools"

    # Generate man pages
    if command -v pandoc >/dev/null 2>&1; then
        log_info "Generating man pages with pandoc..."
        
        # Man page for create-subvolume
        if [ -f "doc/create-subvolume.md" ]; then
            log_debug "Processing create-subvolume.md"
            pandoc -s -t man doc/create-subvolume.md -o /tmp/create-subvolume.8
            gzip -f /tmp/create-subvolume.8
            install -m 644 /tmp/create-subvolume.8.gz "${install_root}/share/man/man8/"
            rm /tmp/create-subvolume.8.gz
        else
            log_warning "doc/create-subvolume.md not found, skipping man page"
        fi
        
        # Man page for configure-snapshots
        if [ -f "doc/configure-snapshots.md" ]; then
            log_debug "Processing configure-snapshots.md"
            pandoc -s -t man doc/configure-snapshots.md -o /tmp/configure-snapshots.8
            gzip -f /tmp/configure-snapshots.8
            install -m 644 /tmp/configure-snapshots.8.gz "${install_root}/share/man/man8/"
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
        install -m 755 bin/create-subvolume.sh "${install_root}/bin/create-subvolume"
    else
        log_error "bin/create-subvolume.sh not found"
        return 1
    fi

    if [ -f "bin/configure-snapshots.sh" ]; then
        log_info "Installing configure-snapshots script..."
        install -m 755 bin/configure-snapshots.sh "${install_root}/bin/configure-snapshots"
    else
        log_error "bin/configure-snapshots.sh not found"
        return 1
    fi

    # Install documentation
    log_info "Installing documentation..."
    for doc in README.md CHANGELOG.md LICENSE; do
        if [ -f "$doc" ]; then
            install -m 644 "$doc" "${install_root}/share/doc/btrfs-subvolume-tools/"
        else
            log_warning "$doc not found, skipping"
        fi
    done

    # Update man database if mandb is available and not in DESTDIR mode
    if [ -z "$destdir" ] && command -v mandb >/dev/null 2>&1; then
        log_info "Updating man database..."
        mandb >/dev/null 2>&1 || true
    fi

    # Check for dependencies if not in DESTDIR mode (package building)
    if [ -z "$destdir" ]; then
        log_info "Checking for dependencies..."
        
        # Check for btrfs-progs
        if ! command -v btrfs >/dev/null 2>&1; then
            log_warning "btrfs-progs not found. This is required for BTRFS operations."
        fi
        
        # Check for snapper
        if ! command -v snapper >/dev/null 2>&1; then
            log_warning "snapper not found. This is required for snapshot management."
        fi
    fi

    log_info "Installation completed successfully to ${install_root}"
    
    # Only show usage information if not in DESTDIR mode (package building)
    if [ -z "$destdir" ]; then
        log_info "You can now use:"
        log_info "  create-subvolume    - To create and configure btrfs subvolumes"
        log_info "  configure-snapshots - To set up snapper for automated snapshots"
        log_info "See the man pages for more information:"
        log_info "  man create-subvolume"
        log_info "  man configure-snapshots"
    fi
    
    return 0
}

# Main function
main() {
    # Log start of installation
    log_journal "info" "Starting BTRFS Subvolume Tools installation"
    
    # Default settings
    PACKAGE_MODE=false
    CREATE_PKGFILES=false
    
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
                --package)
                    PACKAGE_MODE=true
                    log_journal "info" "Package creation mode enabled"
                    shift
                    ;;
                --create-pkgfiles)
                    CREATE_PKGFILES=true
                    log_journal "info" "Package file generation mode enabled"
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
    
    # If in package file generation mode, create packaging files
    if [ "$CREATE_PKGFILES" = true ]; then
        create_packaging_files
        exit 0
    fi
    
    # If in package mode, suggest native packaging
    if [ "$PACKAGE_MODE" = true ]; then
        suggest_native_packaging
        exit 0
    else
        # For regular installation, suggest native packaging but continue
        suggest_native_packaging
    fi
    
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