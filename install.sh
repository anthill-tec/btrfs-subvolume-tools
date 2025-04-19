#!/bin/bash
# Remove the set -e to prevent premature exits on command failures
# We'll handle errors explicitly instead

# Check if PACKAGE_NAME is set
if [ -z "${PACKAGE_NAME}" ]; then
    echo "ERROR: PACKAGE_NAME environment variable is not set."
    echo "Please set the PACKAGE_NAME environment variable before running this script."
    echo "Example: PACKAGE_NAME=my-package ./install.sh"
    exit 1
fi

PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Identifier for systemd journal logging
IDENTIFIER="${PACKAGE_NAME}-installer"

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
        local package_name="${PACKAGE_NAME}"
        local log_file="/tmp/${package_name}-install.log"
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
    local package_name="${PACKAGE_NAME}"
    echo "${package_name} Installer"
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
    echo "  <prefix>/share/doc/${package_name} - Documentation"
    echo "  <prefix>/share/${package_name}/lib - Shared library files"
    echo ""
}

# Suggest native packaging based on distribution
suggest_native_packaging() {
    local package_name="${PACKAGE_NAME}"
    
    # Detect distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME="$NAME"
    else
        DISTRO_NAME="Unknown"
    fi
    
    echo "Detected distribution: $DISTRO_NAME"
    echo ""
    echo "For better integration with your system, consider using native packaging:"
    echo ""
    
    case "$DISTRO_NAME" in
        "Arch Linux")
            echo "For Arch Linux, you can create a package using:"
            echo ""
            echo "  # Option 1: Use the Makefile target (recommended)"
            echo "  make pkg-arch"
            echo ""
            echo "  # Option 2: Build manually"
            echo "  cd .dist/arch"
            echo "  makepkg -si"
            echo ""
            echo "This will create and install a proper Arch package."
            echo ""
            echo "Dependencies: bash, btrfs-progs, snapper, dialog"
            echo "Build-Dependencies: pandoc"
            ;;
        "Debian GNU/Linux"|"Ubuntu")
            echo "For Debian/Ubuntu, you can create a package using:"
            echo ""
            echo "  # Option 1: Use the Makefile target (recommended)"
            echo "  make pkg-deb"
            echo ""
            echo "  # Option 2: Build manually"
            echo "  cd .dist/debian"
            echo "  dpkg-buildpackage -us -uc -b"
            echo "  sudo dpkg -i ../${package_name}_*.deb"
            echo ""
            echo "This will create and install a proper Debian package."
            echo ""
            echo "Dependencies: bash, btrfs-progs, snapper, dialog"
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
    
    log_info "Creating packaging files for $DISTRO_NAME"
    
    # Create dist directory if it doesn't exist
    mkdir -p .dist
    
    # Get version from Makefile if possible
    VERSION="1.0.0"
    if grep -q "^VERSION" Makefile; then
        VERSION=$(grep "^VERSION" Makefile | cut -d'=' -f2 | tr -d ' ')
    fi
    
    # Set maintainer info from environment variables or use defaults
    MAINTAINER_NAME="${MAINTAINER_NAME:-Your Name Here}"
    MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-your.email@example.com}"
    MAINTAINER="${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>"
    
    # Create Arch Linux PKGBUILD
    cat > .dist/arch/PKGBUILD << EOF
# Maintainer: ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>
pkgname=${package_name}
pkgver=${VERSION}
pkgrel=1
pkgdesc="Tools for managing BTRFS subvolumes and snapshots"
arch=('any')
url="https://github.com/anthill-tec/${package_name}"
license=('GPL3')
depends=('bash' 'btrfs-progs' 'snapper' 'dialog')
makedepends=('pandoc')
backup=('etc/${package_name}/config')
source=("${package_name}-${VERSION}.tar.gz")
sha256sums=('SKIP')

package() {
  cd "\$srcdir/\$pkgname-\$pkgver"
  
  # Create directories
  mkdir -p "\$pkgdir/usr/bin"
  mkdir -p "\$pkgdir/usr/share/man/man8"
  mkdir -p "\$pkgdir/etc/${package_name}"
  mkdir -p "\$pkgdir/usr/share/${package_name}/lib"
  
  # Install binaries
  for script in bin/*.sh; do
    script_name=\$(basename "\$script" .sh)
    install -Dm755 "\$script" "\$pkgdir/usr/bin/\$script_name"
  done
  
  # Install shared library files
  if [ -d "share/${package_name}/lib" ]; then
    for lib in share/${package_name}/lib/*.sh; do
      if [ -f "\$lib" ]; then
        install -Dm644 "\$lib" "\$pkgdir/usr/share/${package_name}/lib/\$(basename \$lib)"
      fi
    done
  fi
  
  # Install man pages
  install -Dm644 man/*.8.gz "\$pkgdir/usr/share/man/man8/"
  
  # Install config file
  if [ -f "docs/config.example" ]; then
    install -Dm644 docs/config.example "\$pkgdir/etc/${package_name}/config"
  else
    echo "# BTRFS Subvolume Tools Configuration" > "\$pkgdir/etc/${package_name}/config"
    echo "# Created during package installation" >> "\$pkgdir/etc/${package_name}/config"
  fi
}
EOF
    
    # Create Debian control file
    cat > .dist/debian/control << EOF
Source: ${package_name}
Section: admin
Priority: optional
Maintainer: ${MAINTAINER}
Build-Depends: debhelper (>= 10), pandoc
Standards-Version: 4.5.0
Homepage: https://github.com/anthill-tec/${package_name}
Vcs-Browser: https://github.com/anthill-tec/${package_name}
Vcs-Git: https://github.com/anthill-tec/${package_name}.git

Package: ${package_name}
Architecture: all
Depends: bash, btrfs-progs, snapper, dialog
Description: Tools for managing BTRFS subvolumes and snapshots
 This package provides tools for creating and managing BTRFS subvolumes
 and snapshots, including automated snapshot configuration.
 .
 This package provides utilities to:
  * Create and configure BTRFS subvolumes
  * Set up snapper for automated snapshots
EOF
    
    # Create Debian rules file
    cat > .dist/debian/rules << EOF
#!/usr/bin/make -f
%:
	dh \$@

override_dh_auto_install:
	mkdir -p debian/${package_name}/usr/bin
	mkdir -p debian/${package_name}/usr/share/man/man8
	mkdir -p debian/${package_name}/etc/${package_name}
	mkdir -p debian/${package_name}/usr/share/${package_name}/lib
	for script in bin/*.sh; do
		script_name=\\\$(basename "\\\$script" .sh)
		install -Dm755 "\\\$script" debian/${package_name}/usr/bin/"\\\$script_name"
	done
	# Install shared library files
	if [ -d "share/${package_name}/lib" ]; then
		for lib in share/${package_name}/lib/*.sh; do
			if [ -f "\\\$lib" ]; then
				install -Dm644 "\\\$lib" debian/${package_name}/usr/share/${package_name}/lib/\\\$(basename "\\\$lib")
			fi
		done
	fi
	install -Dm644 man/*.8.gz debian/${package_name}/usr/share/man/man8/
	install -Dm644 docs/config.example debian/${package_name}/etc/${package_name}/config
EOF
    
    # Create Debian changelog
    cat > .dist/debian/changelog << EOF
${package_name} (${VERSION}) unstable; urgency=medium

  * Initial release.

 -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  Sun, 30 Mar 2025 08:00:00 +0530
EOF
    
    # Create Debian compat file
    echo "10" > .dist/debian/compat
    
    # Make rules file executable
    chmod +x .dist/debian/rules
    
    log_info "Packaging files created successfully in .dist/ directory"
    log_info "You may need to customize these files for your specific needs"
    
    echo ""
    echo "==============================================================="
    echo "  Packaging files created for $DISTRO_NAME"
    echo "==============================================================="
    echo ""
    echo "Files created:"
    echo "  - .dist/arch/PKGBUILD"
    echo "  - .dist/debian/control"
    echo "  - .dist/debian/rules"
    echo "  - .dist/debian/changelog"
    echo "  - .dist/debian/compat"
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
    local package_name="${PACKAGE_NAME}"
    
    log_info "Installing $package_name to ${install_root}"

    # Create directories if they don't exist
    mkdir -p "${install_root}/bin"
    mkdir -p "${install_root}/share/man/man8"
    mkdir -p "${install_root}/share/doc/$package_name"
    mkdir -p "${install_root}/etc/$package_name"
    mkdir -p "${install_root}/share/$package_name/lib"
    
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
    log_info "Installing scripts..."
    for script in bin/*.sh; do
        if [ -f "$script" ]; then
            script_name=$(basename "$script" .sh)
            log_info "Installing $script_name script..."
            install -m 755 "$script" "${install_root}/bin/$script_name"
        else
            log_error "Script $script not found"
            return 1
        fi
    done

    # Install documentation
    log_info "Installing documentation..."
    for doc in README.md CHANGELOG.md LICENSE; do
        if [ -f "$doc" ]; then
            install -m 644 "$doc" "${install_root}/share/doc/$package_name/"
        else
            log_warning "$doc not found, skipping"
        fi
    done

    # Install shared library files
    log_info "Installing shared library files..."
    if [ -d "share/$package_name/lib" ]; then
        for lib in share/$package_name/lib/*.sh; do
            if [ -f "$lib" ]; then
                lib_name=$(basename "$lib")
                log_info "Installing library: $lib_name"
                install -m 644 "$lib" "${install_root}/share/$package_name/lib/"
            fi
        done
    else
        log_warning "Library directory not found, skipping library installation"
    fi

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
                    log_info "Package file generation mode enabled"
                    CREATE_PKGFILES=true
                    
                    # Check for distribution specification
                    if [ "$2" == "--arch" ]; then
                        log_info "Creating packaging files for Arch Linux"
                        create_arch_package_files
                        exit 0
                    elif [ "$2" == "--debian" ]; then
                        log_info "Creating packaging files for Debian Linux"
                        create_debian_package_files
                        exit 0
                    else
                        # Default behavior: create all package files
                        detect_distribution
                        log_info "Creating packaging files for $DISTRO_NAME (base: $DISTRO_ID)"
                        create_package_files
                        exit 0
                    fi
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

# Function to create package files for Arch Linux
create_arch_package_files() {
    local package_name="${PACKAGE_NAME}"
    mkdir -p .dist/arch
    
    # Create PKGBUILD with properly expanded variables
    cat > .dist/arch/PKGBUILD << EOF
# Maintainer: ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>
pkgname=${package_name}
pkgver=${VERSION}
pkgrel=1
pkgdesc="Tools for managing BTRFS subvolumes and snapshots"
arch=('any')
url="https://github.com/anthill-tec/${package_name}"
license=('GPL3')
depends=('bash' 'btrfs-progs' 'snapper' 'dialog')
makedepends=('pandoc')
backup=('etc/${package_name}/config')
source=("${package_name}-${VERSION}.tar.gz")
sha256sums=('SKIP')

package() {
  cd "\$srcdir/\$pkgname-\$pkgver"
  
  # Create directories
  mkdir -p "\$pkgdir/usr/bin"
  mkdir -p "\$pkgdir/usr/share/man/man8"
  mkdir -p "\$pkgdir/etc/${package_name}"
  mkdir -p "\$pkgdir/usr/share/${package_name}/lib"
  
  # Install binaries
  for script in bin/*.sh; do
    script_name=\$(basename "\$script" .sh)
    install -Dm755 "\$script" "\$pkgdir/usr/bin/\$script_name"
  done
  
  # Install shared library files
  if [ -d "share/${package_name}/lib" ]; then
    for lib in share/${package_name}/lib/*.sh; do
      if [ -f "\$lib" ]; then
        install -Dm644 "\$lib" "\$pkgdir/usr/share/${package_name}/lib/\$(basename \$lib)"
      fi
    done
  fi
  
  # Install man pages
  install -Dm644 man/*.8.gz "\$pkgdir/usr/share/man/man8/"
  
  # Install config file
  if [ -f "docs/config.example" ]; then
    install -Dm644 docs/config.example "\$pkgdir/etc/${package_name}/config"
  else
    echo "# BTRFS Subvolume Tools Configuration" > "\$pkgdir/etc/${package_name}/config"
    echo "# Created during package installation" >> "\$pkgdir/etc/${package_name}/config"
  fi
}
EOF

    log_info "Arch packaging files created successfully in .dist/arch directory"
}

# Function to create package files for Debian
create_debian_package_files() {
    local package_name="${PACKAGE_NAME}"
    mkdir -p .dist/debian/debian
    
    # Create control file
    cat > .dist/debian/debian/control << EOF
Source: ${package_name}
Section: admin
Priority: optional
Maintainer: ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>
Build-Depends: debhelper (>= 10), pandoc
Standards-Version: 4.5.0
Homepage: https://github.com/anthill-tec/${package_name}
Vcs-Browser: https://github.com/anthill-tec/${package_name}
Vcs-Git: https://github.com/anthill-tec/${package_name}.git

Package: ${package_name}
Architecture: all
Depends: bash, btrfs-progs, snapper, dialog
Description: Tools for managing BTRFS subvolumes and snapshots
 This package provides tools for creating and managing BTRFS subvolumes
 and snapshots, including automated snapshot configuration.
 .
 This package provides utilities to:
  * Create and configure BTRFS subvolumes
  * Set up snapper for automated snapshots
EOF

    # Create rules file
    cat > .dist/debian/debian/rules << EOF
#!/usr/bin/make -f
%:
	dh \$@

override_dh_auto_install:
	mkdir -p debian/${package_name}/usr/bin
	mkdir -p debian/${package_name}/usr/share/man/man8
	mkdir -p debian/${package_name}/etc/${package_name}
	mkdir -p debian/${package_name}/usr/share/${package_name}/lib
	for script in bin/*.sh; do
		script_name=\\\$(basename "\\\$script" .sh)
		install -Dm755 "\\\$script" debian/${package_name}/usr/bin/"\\\$script_name"
	done
	# Install shared library files
	if [ -d "share/${package_name}/lib" ]; then
		for lib in share/${package_name}/lib/*.sh; do
			if [ -f "\\\$lib" ]; then
				install -Dm644 "\\\$lib" debian/${package_name}/usr/share/${package_name}/lib/\\\$(basename "\\\$lib")
			fi
		done
	fi
	install -Dm644 man/*.8.gz debian/${package_name}/usr/share/man/man8/
	install -Dm644 docs/config.example debian/${package_name}/etc/${package_name}/config
EOF
    
    # Create changelog
    cat > .dist/debian/debian/changelog << EOF
${package_name} (${VERSION}) unstable; urgency=medium

  * Initial release.

 -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  Sun, 30 Mar 2025 08:00:00 +0530
EOF
    
    # Create Debian compat file
    echo "10" > .dist/debian/debian/compat
    
    # Make rules file executable
    chmod +x .dist/debian/debian/rules
    
    log_info "Debian packaging files created successfully in .dist/debian directory"
}

# Function to create all package files (for backward compatibility)
create_package_files() {
    create_arch_package_files
    create_debian_package_files
}

# Display usage information
usage() {
    local package_name="${PACKAGE_NAME}"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help, -h              Display this help message"
    echo "  --prefix=<prefix>       Set installation prefix (default: /usr)"
    echo "  --destdir=<destdir>     Set destination directory for staged installs"
    echo "  --create-package        Create package files only, don't install"
    echo "  --uninstall             Uninstall the package"
    echo ""
    echo "Installation paths:"
    echo "  <prefix>/bin - Executable scripts"
    echo "  <prefix>/share/man/man8 - Man pages"
    echo "  <prefix>/etc/${package_name} - Configuration files"
    echo "  <prefix>/share/doc/${package_name} - Documentation"
    echo "  <prefix>/share/${package_name}/lib - Shared library files"
    echo ""
    echo "Example:"
    echo "  $0 --prefix=/usr"
    echo "  $0 --destdir=/tmp/stage --prefix=/usr"
    echo "  $0 --create-package"
    echo "  $0 --uninstall"
}

# Run main function
main "$@"