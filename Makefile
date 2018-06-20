CRYSTAL = crystal
CRFLAGS =
SOURCES = $(shell find src -type f)

DESTDIR =
PREFIX = /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin
INSTALL = /usr/bin/install

all: bin/gwt

bin/gwt: $(SOURCES)
	@mkdir -p bin
	$(CRYSTAL) build src/entrypoint.cr -o bin/gwt $(CRFLAGS)

.PHONY: install
install: bin/gwt
	$(INSTALL) -m 0755 -d "$(BINDIR)"
	$(INSTALL) -m 0755 -t "$(BINDIR)" bin/gwt

.PHONY: uninstall
uninstall:
	rm -f "$(BINDIR)/gwt"

.PHONY: clean
clean:
	rm -Rf bin
