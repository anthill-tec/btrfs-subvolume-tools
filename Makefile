# Makefile for btrfs-subvolume-tools

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man
DOCDIR = $(PREFIX)/share/doc/btrfs-subvolume-tools
CONFDIR = $(PREFIX)/etc/btrfs-subvolume-tools
PROJECT_NAME = "BTRFS Subvolume Tools"
VERSION = 1.0.0

# Directory structure for package building
PKGDIR = packaging
ARCHPKGDIR = $(PKGDIR)/arch
DEBPKGDIR = $(PKGDIR)/debian
TESTDIR = tests
TESTLOGDIR = $(TESTDIR)/logs

.PHONY: all install uninstall man clean check-deps pkg-arch pkg-deb pkg test debug-test test-clean help

# Default target shows help
.DEFAULT_GOAL := help

help:
	@echo "$(PROJECT_NAME) Makefile"
	@echo ""
	@echo "Development targets:"
	@echo "  make all          - Generate man pages"
	@echo "  make test         - Run tests (requires root)"
	@echo "  make debug-test   - Run tests with debug output (requires root)"
	@echo "  make test-clean   - Clean up test environment"
	@echo ""
	@echo "Installation targets:"
	@echo "  make install      - Install directly (development mode)"
	@echo "  make uninstall    - Uninstall direct installation"
	@echo ""
	@echo "Packaging targets (recommended for deployment):"
	@echo "  make pkg          - Build package for detected system"
	@echo "  make pkg-arch     - Build Arch Linux package"
	@echo "  make pkg-deb      - Build Debian package"
	@echo "  make pkg-files    - Generate packaging files"
	@echo ""
	@echo "Other targets:"
	@echo "  make clean        - Remove generated files"
	@echo "  make check-deps   - Check for dependencies"
	@echo "  make man          - Generate man pages"

all: man

# Direct installation method (for development or systems without package managers)
# For production deployments, prefer using the package targets (pkg, pkg-arch, pkg-deb)
install: check-deps all
	@echo "Installing $(PROJECT_NAME) directly (development mode)..."
	@echo "Note: For production deployments, consider using 'make pkg' instead."
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 bin/create-subvolume.sh $(DESTDIR)$(BINDIR)/create-subvolume
	install -m 0755 bin/configure-snapshots.sh $(DESTDIR)$(BINDIR)/configure-snapshots
	install -d $(DESTDIR)$(MANDIR)/man8
	install -m 0644 doc/create-subvolume.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -m 0644 doc/configure-snapshots.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -d $(DESTDIR)$(DOCDIR)
	install -m 0644 README.md $(DESTDIR)$(DOCDIR)/
	install -m 0644 CHANGELOG.md $(DESTDIR)$(DOCDIR)/
	install -d $(DESTDIR)$(CONFDIR)

# Uninstall when installed directly (not for package-managed installations)
uninstall:
	@echo "Uninstalling $(PROJECT_NAME) (only for direct installations)..."
	@echo "Note: If installed via package manager, use your package manager to uninstall."
	rm -f $(DESTDIR)$(BINDIR)/create-subvolume
	rm -f $(DESTDIR)$(BINDIR)/configure-snapshots
	rm -f $(DESTDIR)$(MANDIR)/man8/create-subvolume.8.gz
	rm -f $(DESTDIR)$(MANDIR)/man8/configure-snapshots.8.gz
	rm -rf $(DESTDIR)$(DOCDIR)
	rm -rf $(DESTDIR)$(CONFDIR)

man: doc/create-subvolume.8.gz doc/configure-snapshots.8.gz

doc/create-subvolume.8: doc/create-subvolume.md
	pandoc -s -t man doc/create-subvolume.md -o doc/create-subvolume.8

doc/create-subvolume.8.gz: doc/create-subvolume.8
	gzip -f doc/create-subvolume.8

doc/configure-snapshots.8: doc/configure-snapshots.md
	pandoc -s -t man doc/configure-snapshots.md -o doc/configure-snapshots.8

doc/configure-snapshots.8.gz: doc/configure-snapshots.8
	gzip -f doc/configure-snapshots.8

# Check for dependencies
check-deps:
	@echo "Checking dependencies..."
	@command -v btrfs >/dev/null 2>&1 || { echo "ERROR: btrfs-progs not found. Please install it first."; exit 1; }
	@command -v snapper >/dev/null 2>&1 || { echo "WARNING: snapper not found. It's recommended for snapshot management."; }
	@command -v pandoc >/dev/null 2>&1 || { echo "WARNING: pandoc not found. Man pages won't be generated."; }

# Development mode test targets
# Run tests with the test orchestrator
test:
	@echo "Running tests (requires root privileges)..."
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Please run: sudo make test"; \
		exit 1; \
	fi
	@$(TESTDIR)/test-orchestrator.sh $(if $(debug),--debug,) $(if $(test-suite),--test-suite=$(test-suite),) $(if $(test-case),--test-case=$(test-case),) --project-name=$(PROJECT_NAME)

# Run tests in debug mode
debug-test:
	@echo "Running tests in debug mode (requires root privileges)..."
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Please run: sudo make debug-test"; \
		exit 1; \
	fi
	@DEBUG=true $(TESTDIR)/test-orchestrator.sh --debug --project-name=$(PROJECT_NAME)

# Clean up test environment
test-clean:
	@echo "Cleaning up test environment..."
	@rm -rf $(TESTDIR)/container
	@rm -rf $(TESTLOGDIR)

# Package building targets
# Create packaging files
pkg-files:
	@echo "Creating packaging files..."
	@mkdir -p $(PKGDIR)
	@mkdir -p $(ARCHPKGDIR)
	@mkdir -p $(DEBPKGDIR)
	@./install.sh --create-pkgfiles
	@echo "Packaging files created in $(PKGDIR) directory"

# Build an Arch Linux package
pkg-arch: man pkg-files
	@echo "Building Arch Linux package..."
	@if [ ! -d "$(ARCHPKGDIR)" ]; then \
		echo "Packaging files not found. Run 'make pkg-files' first."; \
		exit 1; \
	fi
	@cd $(ARCHPKGDIR) && makepkg -f

# Build a Debian package
pkg-deb: man pkg-files
	@echo "Building Debian package..."
	@if [ ! -d "$(DEBPKGDIR)" ]; then \
		echo "Packaging files not found. Run 'make pkg-files' first."; \
		exit 1; \
	fi
	@cd $(PKGDIR) && dpkg-buildpackage -us -uc -b

# Detect system and build appropriate package
pkg:
	@if command -v pacman >/dev/null 2>&1; then \
		echo "Arch-based system detected, building pacman package..."; \
		$(MAKE) pkg-arch; \
	elif command -v dpkg >/dev/null 2>&1; then \
		echo "Debian-based system detected, building deb package..."; \
		$(MAKE) pkg-deb; \
	else \
		echo "Unknown system type. Please use 'make pkg-arch' or 'make pkg-deb' directly."; \
		exit 1; \
	fi

clean: test-clean
	rm -f doc/create-subvolume.8*
	rm -f doc/configure-snapshots.8*
	rm -rf $(ARCHPKGDIR)/pkg
	rm -rf $(ARCHPKGDIR)/src
	rm -rf $(ARCHPKGDIR)/*.tar.gz
	rm -f $(PKGDIR)/*.deb
	rm -f $(PKGDIR)/*.changes
	rm -f $(PKGDIR)/*.buildinfo