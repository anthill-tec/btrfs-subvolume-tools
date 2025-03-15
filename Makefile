# Makefile for btrfs-subvolume-tools

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man
DOCDIR = $(PREFIX)/share/doc/btrfs-subvolume-tools

.PHONY: all install uninstall man clean test test-clean

all: man

install: all
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 bin/create-subvolume.sh $(DESTDIR)$(BINDIR)/create-subvolume
	install -m 0755 bin/configure-snapshots.sh $(DESTDIR)$(BINDIR)/configure-snapshots
	install -d $(DESTDIR)$(MANDIR)/man8
	install -m 0644 doc/create-subvolume.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -m 0644 doc/configure-snapshots.8.gz $(DESTDIR)$(MANDIR)/man8/
	install -d $(DESTDIR)$(DOCDIR)
	install -m 0644 README.md $(DESTDIR)$(DOCDIR)/
	install -m 0644 CHANGELOG.md $(DESTDIR)$(DOCDIR)/

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/create-subvolume
	rm -f $(DESTDIR)$(BINDIR)/configure-snapshots
	rm -f $(DESTDIR)$(MANDIR)/man8/create-subvolume.8.gz
	rm -f $(DESTDIR)$(MANDIR)/man8/configure-snapshots.8.gz
	rm -rf $(DESTDIR)$(DOCDIR)

man: doc/create-subvolume.8.gz doc/configure-snapshots.8.gz

doc/create-subvolume.8: doc/create-subvolume.md
	pandoc -s -t man doc/create-subvolume.md -o doc/create-subvolume.8

doc/create-subvolume.8.gz: doc/create-subvolume.8
	gzip -f doc/create-subvolume.8

doc/configure-snapshots.8: doc/configure-snapshots.md
	pandoc -s -t man doc/configure-snapshots.md -o doc/configure-snapshots.8

doc/configure-snapshots.8.gz: doc/configure-snapshots.8
	gzip -f doc/configure-snapshots.8

test:
	@echo "Running tests with systemd-nspawn..."
	@./install.sh --test

test-clean:
	@echo "Cleaning up test environment..."
	@rm -rf tests/container

clean:
	rm -f doc/create-subvolume.8*
	rm -f doc/configure-snapshots.8*
	rm -rf tests/container
