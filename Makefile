# Makefile for btrfs-subvolume-tools

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man
PROJECT_NAME = BTRFS Subvolume Tools
# Automatically derive package name from project name (lowercase, replace spaces with hyphens)
PACKAGE_NAME = $(shell echo "$(PROJECT_NAME)" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
# Package information
VERSION = 1.0.0
MAINTAINER_NAME = Antony John
MAINTAINER_EMAIL = still.duck5711@fastmail.com
MAINTAINER = $(MAINTAINER_NAME) <$(MAINTAINER_EMAIL)>
DOCDIR = $(PREFIX)/share/doc/$(PACKAGE_NAME)
CONFDIR = $(PREFIX)/etc/$(PACKAGE_NAME)

# Directory structure for package building
PKGDIR = .dist
ARCHPKGDIR = $(PKGDIR)/arch
DEBPKGDIR = $(PKGDIR)/debian
TESTDIR = tests
TESTLOGDIR = $(TESTDIR)/logs
TARBALL_NAME = $(PACKAGE_NAME)-$(VERSION)

.PHONY: all install uninstall man clean check-deps pkg-arch pkg-deb pkg test debug-test test-clean help print-project-name print-package-name

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

# Debug targets to print variable values
print-project-name:
	@echo $(PROJECT_NAME)

print-package-name:
	@echo $(PACKAGE_NAME)

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
	install -m 0644 man/create-subvolume.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -m 0644 man/configure-snapshots.8.gz $(DESTDIR)$(MANDIR)/man8/
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

man:
	@mkdir -p man
	@pandoc -s -t man docs/create-subvolume.md -o man/create-subvolume.8
	@gzip -f man/create-subvolume.8
	@pandoc -s -t man docs/configure-snapshots.md -o man/configure-snapshots.8
	@gzip -f man/configure-snapshots.8

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
	@$(TESTDIR)/test-orchestrator.sh $(if $(debug),--debug,) $(if $(test-suite),--test-suite=$(test-suite),) $(if $(test-case),--test-case=$(test-case),) --project-name="$(PROJECT_NAME)"

# Run tests in debug mode
debug-test:
	@echo "Running tests in debug mode (requires root privileges)..."
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Please run: sudo make debug-test"; \
		exit 1; \
	fi
	@DEBUG=true $(TESTDIR)/test-orchestrator.sh --debug --project-name="$(PROJECT_NAME)"

# Clean up test environment
test-clean:
	@echo "Cleaning up test environment..."
	@rm -rf $(TESTDIR)/container
	@rm -rf $(TESTLOGDIR)

# Create source tarball for packaging
dist: man
	@echo "Creating source tarball..."
	@mkdir -p $(PKGDIR)
	@TMP_DIR=$$(mktemp -d); \
	DEST="$$TMP_DIR/$(TARBALL_NAME)"; \
	mkdir -p "$$DEST/man"; \
	mkdir -p "$$DEST/bin" "$$DEST/docs"; \
	echo "Copying required files..."; \
	cp -r bin/* "$$DEST/bin/" || { echo "Error: bin directory content missing"; exit 1; }; \
	cp docs/*.md "$$DEST/docs/" || { echo "Error: docs/*.md files missing"; exit 1; }; \
	cp man/*.8.gz "$$DEST/man/" || { echo "Error: Man pages missing. Run 'make man' first"; exit 1; }; \
	cp README.md LICENSE Makefile install.sh logging.sh "$$DEST/" || { echo "Error: Required files missing"; exit 1; }; \
	[ -f CHANGELOG.md ] && cp CHANGELOG.md "$$DEST/" || echo "Note: CHANGELOG.md not found, creating placeholder"; \
	[ -f "$$DEST/CHANGELOG.md" ] || echo "# Changelog\n\n## $(VERSION)\n\n- Initial release" > "$$DEST/CHANGELOG.md"; \
	echo "Creating tarball..."; \
	tar -czf $(PKGDIR)/$(TARBALL_NAME).tar.gz -C "$$TMP_DIR" .; \
	rm -rf "$$TMP_DIR"
	@echo "Source tarball created at $(PKGDIR)/$(TARBALL_NAME).tar.gz"
	@mkdir -p $(ARCHPKGDIR)
	@cp $(PKGDIR)/$(TARBALL_NAME).tar.gz $(ARCHPKGDIR)

# Arch-specific packaging files
pkg-files-arch: dist
	@echo "Creating Arch packaging files..."
	@mkdir -p $(ARCHPKGDIR)/src
	@cp $(PKGDIR)/$(TARBALL_NAME).tar.gz $(ARCHPKGDIR)/src/
	@PACKAGE_NAME="$(PACKAGE_NAME)" VERSION="$(VERSION)" MAINTAINER_NAME="$(MAINTAINER_NAME)" MAINTAINER_EMAIL="$(MAINTAINER_EMAIL)" ./install.sh --create-pkgfiles --arch
	@echo "Arch packaging files created in $(ARCHPKGDIR)"
	@echo "Updating checksums..."
	@cd $(ARCHPKGDIR) && \
	sed -i "s/sha256sums=.*/sha256sums=('$$(sha256sum src/$(TARBALL_NAME).tar.gz | cut -d' ' -f1)')/" PKGBUILD && \
	echo "Checksums and metadata updated successfully"

# Debian-specific packaging files
pkg-files-deb: dist
	@echo "Creating Debian packaging files..."
	@mkdir -p $(DEBPKGDIR)
	@cp $(PKGDIR)/$(TARBALL_NAME).tar.gz $(DEBPKGDIR)/
	@PACKAGE_NAME="$(PACKAGE_NAME)" VERSION="$(VERSION)" MAINTAINER_NAME="$(MAINTAINER_NAME)" MAINTAINER_EMAIL="$(MAINTAINER_EMAIL)" ./install.sh --create-pkgfiles --debian
	@echo "Debian packaging files created in $(DEBPKGDIR)"

# Update checksums (depends on Arch files)
update-checksums: pkg-files-arch
	@echo "Updating checksums..."
	@cd $(ARCHPKGDIR) && \
	sed -i "s|source=.*|source=(\"$(TARBALL_NAME).tar.gz\")|" PKGBUILD && \
	makepkg -g >> PKGBUILD && \
	makepkg --printsrcinfo > .SRCINFO
	@echo "Checksums and metadata updated successfully"

# Build Arch package
pkg-arch: update-checksums
	@echo "Building Arch package..."
	@cd $(ARCHPKGDIR) && makepkg -s --clean --force --noconfirm
	@mv $(ARCHPKGDIR)/*.pkg.tar.zst $(PKGDIR)/
	@echo "Package built: $(PKGDIR)/$(PACKAGE_NAME)-$(VERSION)-1-any.pkg.tar.zst"

# Build Debian package
pkg-deb: pkg-files-deb
	@echo "Building Debian package..."
	@if [ -d "$(DEBPKGDIR)" ]; then \
		if command -v dpkg-buildpackage >/dev/null 2>&1; then \
			if cd $(DEBPKGDIR) && dpkg-checkbuilddeps 2>/dev/null; then \
				dpkg-buildpackage -us -uc -b && \
				mv ../*.deb $(PKGDIR)/ && \
				echo "Debian package built: $(PKGDIR)/$(PACKAGE_NAME)_$(VERSION)_all.deb"; \
			else \
				echo "WARNING: Build dependencies not satisfied. Creating simplified Debian package..."; \
				ROOT_DIR="$$(cd "$(CURDIR)" && pwd)"; \
				TARBALL_PATH="$$ROOT_DIR/$(PKGDIR)/$(TARBALL_NAME).tar.gz"; \
				echo "Using tarball at: $$TARBALL_PATH"; \
				if [ -f "$$TARBALL_PATH" ]; then \
					echo "Tarball exists, proceeding with extraction"; \
					rm -rf "$$ROOT_DIR/$(PKGDIR)/extract" "$$ROOT_DIR/$(PKGDIR)/deb"; \
					mkdir -p "$$ROOT_DIR/$(PKGDIR)/extract" "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN" "$$ROOT_DIR/$(PKGDIR)/deb/usr/bin" "$$ROOT_DIR/$(PKGDIR)/deb/usr/share/man/man8"; \
					cd "$$ROOT_DIR/$(PKGDIR)/extract" && tar -xzf "$$TARBALL_PATH"; \
					ls -la "$$ROOT_DIR/$(PKGDIR)/extract"; \
					EXTRACT_DIR="$$ROOT_DIR/$(PKGDIR)/extract/$(TARBALL_NAME)"; \
					if [ -d "$$EXTRACT_DIR" ] && [ -f "$$EXTRACT_DIR/bin/create-subvolume.sh" ]; then \
						echo "Found source files in $$EXTRACT_DIR"; \
						cp "$$EXTRACT_DIR/bin/create-subvolume.sh" "$$ROOT_DIR/$(PKGDIR)/deb/usr/bin/create-subvolume"; \
						cp "$$EXTRACT_DIR/bin/configure-snapshots.sh" "$$ROOT_DIR/$(PKGDIR)/deb/usr/bin/configure-snapshots"; \
						chmod 755 "$$ROOT_DIR/$(PKGDIR)/deb/usr/bin/create-subvolume" "$$ROOT_DIR/$(PKGDIR)/deb/usr/bin/configure-snapshots"; \
						if [ -d "$$EXTRACT_DIR/man" ] && [ -f "$$EXTRACT_DIR/man/create-subvolume.8.gz" ]; then \
							cp "$$EXTRACT_DIR/man/"*.8.gz "$$ROOT_DIR/$(PKGDIR)/deb/usr/share/man/man8/"; \
						fi; \
						echo "Package: $(PACKAGE_NAME)" > "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Version: $(VERSION)" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Section: admin" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Priority: optional" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Architecture: all" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Depends: bash, btrfs-progs, snapper" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Maintainer: $(MAINTAINER)" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo "Description: Tools for managing BTRFS subvolumes and snapshots" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo " This package provides tools for creating and managing BTRFS subvolumes" >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						echo " and snapshots, including automated snapshot configuration." >> "$$ROOT_DIR/$(PKGDIR)/deb/DEBIAN/control"; \
						cd "$$ROOT_DIR" && dpkg-deb --build --root-owner-group "$(PKGDIR)/deb" "$(PKGDIR)/$(PACKAGE_NAME)_$(VERSION)_all.deb" && \
						echo "Simplified Debian package built: $(PKGDIR)/$(PACKAGE_NAME)_$(VERSION)_all.deb"; \
					else \
						echo "ERROR: Source files not found in tarball"; \
						echo "Expected files in: $$EXTRACT_DIR"; \
						find "$$ROOT_DIR/$(PKGDIR)/extract" -type f | sort; \
						exit 1; \
					fi; \
					rm -rf "$$ROOT_DIR/$(PKGDIR)/extract" "$$ROOT_DIR/$(PKGDIR)/deb"; \
				else \
					echo "ERROR: Tarball not found at $$TARBALL_PATH"; \
					find "$$ROOT_DIR/$(PKGDIR)" -name "*.tar.gz" -type f; \
					exit 1; \
				fi; \
			fi; \
		else \
			echo "ERROR: dpkg-buildpackage not found. Please install dpkg-dev package."; \
			exit 1; \
		fi; \
	else \
		echo "Error: Debian packaging files not found"; \
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
	rm -rf man/
	rm -f docs/create-subvolume.8*
	rm -f docs/configure-snapshots.8*
	rm -rf $(PKGDIR)