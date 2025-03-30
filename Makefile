# Makefile for btrfs-subvolume-tools

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man
DOCDIR = $(PREFIX)/share/doc/btrfs-subvolume-tools
CONFDIR = $(PREFIX)/etc/btrfs-subvolume-tools
PROJECT_NAME = "BTRFS Subvolume Tools"
VERSION = 1.0.0

# Directory structure for package building
PKGDIR = .dist
ARCHPKGDIR = $(PKGDIR)/arch
DEBPKGDIR = $(PKGDIR)/debian
TESTDIR = tests
TESTLOGDIR = $(TESTDIR)/logs
TARBALL_NAME = btrfs-subvolume-tools-$(VERSION)

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
	install -m 0644 docs/create-subvolume.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -m 0644 docs/configure-snapshots.8.gz $(DESTDIR)$(MANDIR)/man8/
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

man: docs/create-subvolume.8.gz docs/configure-snapshots.8.gz

docs/create-subvolume.8: docs/create-subvolume.md
	pandoc -s -t man docs/create-subvolume.md -o docs/create-subvolume.8

docs/create-subvolume.8.gz: docs/create-subvolume.8
	gzip -f docs/create-subvolume.8

docs/configure-snapshots.8: docs/configure-snapshots.md
	pandoc -s -t man docs/configure-snapshots.md -o docs/configure-snapshots.8

docs/configure-snapshots.8.gz: docs/configure-snapshots.8
	gzip -f docs/configure-snapshots.8

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

# Create source tarball for packaging
dist: man
	@echo "Creating source tarball..."
	@mkdir -p $(PKGDIR)
	@TMP_DIR=$$(mktemp -d); \
	DEST="$$TMP_DIR/$(TARBALL_NAME)"; \
	mkdir -p "$$DEST/bin" "$$DEST/docs"; \
	echo "Copying required files..."; \
	cp -r bin/* "$$DEST/bin/" || { echo "Error: bin directory content missing"; exit 1; }; \
	cp docs/*.md "$$DEST/docs/" || { echo "Error: docs/*.md files missing"; exit 1; }; \
	cp docs/*.8.gz "$$DEST/docs/" || { echo "Error: Man pages missing. Run 'make man' first"; exit 1; }; \
	cp README.md LICENSE Makefile install.sh logging.sh "$$DEST/" || { echo "Error: Required files missing"; exit 1; }; \
	[ -f CHANGELOG.md ] && cp CHANGELOG.md "$$DEST/" || echo "Note: CHANGELOG.md not found, creating placeholder"; \
	[ -f "$$DEST/CHANGELOG.md" ] || echo "# Changelog\n\n## $(VERSION)\n\n- Initial release" > "$$DEST/CHANGELOG.md"; \
	echo "Creating tarball..."; \
	tar -czf $(PKGDIR)/$(TARBALL_NAME).tar.gz -C "$$TMP_DIR" .; \
	rm -rf "$$TMP_DIR"
	@echo "Source tarball created at $(PKGDIR)/$(TARBALL_NAME).tar.gz"
	@cp $(PKGDIR)/$(TARBALL_NAME).tar.gz $(ARCHPKGDIR)/

# Build an Arch Linux package
pkg-arch: man pkg-files dist
	@echo "Building Arch Linux package..."
	@if [ ! -d "$(ARCHPKGDIR)" ]; then \
		echo "Packaging files not found. Run 'make pkg-files' first."; \
		exit 1; \
	fi
	@cd $(ARCHPKGDIR) && makepkg -f

# Build a Debian package
pkg-deb: man pkg-files dist
	@echo "Building Debian package..."
	@if [ ! -d "$(DEBPKGDIR)" ]; then \
		echo "Packaging files not found. Run 'make pkg-files' first."; \
		exit 1; \
	fi
	@if command -v dpkg-buildpackage >/dev/null 2>&1; then \
		if dpkg-checkbuilddeps 2>/dev/null; then \
			cd $(PKGDIR) && dpkg-buildpackage -us -uc -b; \
		else \
			echo "WARNING: Build dependencies not satisfied."; \
			echo "Creating simplified Debian package structure instead..."; \
			mkdir -p $(PKGDIR)/deb/DEBIAN $(PKGDIR)/deb/usr/bin $(PKGDIR)/deb/usr/share/man/man8 $(PKGDIR)/deb/usr/share/doc/btrfs-subvolume-tools; \
			cp bin/create-subvolume.sh $(PKGDIR)/deb/usr/bin/create-subvolume; \
			cp bin/configure-snapshots.sh $(PKGDIR)/deb/usr/bin/configure-snapshots; \
			chmod 755 $(PKGDIR)/deb/usr/bin/create-subvolume $(PKGDIR)/deb/usr/bin/configure-snapshots; \
			cp docs/create-subvolume.8.gz $(PKGDIR)/deb/usr/share/man/man8/; \
			cp docs/configure-snapshots.8.gz $(PKGDIR)/deb/usr/share/man/man8/; \
			cp README.md CHANGELOG.md LICENSE $(PKGDIR)/deb/usr/share/doc/btrfs-subvolume-tools/; \
			echo "Package: btrfs-subvolume-tools" > $(PKGDIR)/deb/DEBIAN/control; \
			echo "Version: $(VERSION)" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Section: admin" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Priority: optional" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Architecture: all" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Depends: bash, btrfs-progs, snapper" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Maintainer: Your Name <your.email@example.com>" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo "Description: Tools for managing BTRFS subvolumes and snapshots" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo " This package provides tools for creating and managing BTRFS subvolumes" >> $(PKGDIR)/deb/DEBIAN/control; \
			echo " and snapshots, including automated snapshot configuration." >> $(PKGDIR)/deb/DEBIAN/control; \
			dpkg-deb --build $(PKGDIR)/deb $(PKGDIR)/btrfs-subvolume-tools_$(VERSION)_all.deb; \
			echo "Debian package created at $(PKGDIR)/btrfs-subvolume-tools_$(VERSION)_all.deb"; \
		fi; \
	else \
		echo "ERROR: dpkg-buildpackage not found. Please install the dpkg package."; \
		exit 1; \
	fi

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
	rm -f docs/create-subvolume.8*
	rm -f docs/configure-snapshots.8*
	rm -rf $(ARCHPKGDIR)/pkg
	rm -rf $(ARCHPKGDIR)/src
	rm -rf $(ARCHPKGDIR)/*.tar.gz
	rm -rf $(PKGDIR)/*.tar.gz
	rm -rf $(PKGDIR)/*.deb
	rm -rf $(PKGDIR)/*.changes
	rm -rf $(PKGDIR)/*.dsc