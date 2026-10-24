OPENBSD_SRC?=openbsd/src

.PHONY: all test maped-test pf-test metrics-test install install-bin install-conf install-rc install-man metrics-install uninstall

all:
	@echo "Run 'make install' as root to install maped; 'make test' runs portable component tests."

test: maped-test metrics-test pf-test

maped-test:
	$(MAKE) -C maped test

pf-test:
	src=$$(cd "$(OPENBSD_SRC)" && pwd) && \
	    $(MAKE) -C openbsd test OPENBSD_SRC="$$src"

metrics-test:
	$(MAKE) -C metrics test

install install-bin install-conf install-rc install-man:
	$(MAKE) -C maped $@

metrics-install:
	$(MAKE) -C metrics install

uninstall:
	$(MAKE) -C maped uninstall
	$(MAKE) -C metrics uninstall
