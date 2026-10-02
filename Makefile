OPENBSD_SRC?=/usr/src
PREFIX?=/usr/local
BINDIR?=$(PREFIX)/sbin
LIBEXECDIR?=$(PREFIX)/libexec/maped
MANDIR?=$(PREFIX)/man/man8
SYSCONFDIR?=/etc
RCDIR?=/etc/rc.d

OWNER?=root
GROUP?=wheel
BINMODE?=755
CONFMODE?=600
RCMODE?=555
MANMODE?=444

SCRIPT=maped
METRICS=mape-prometheus-metrics
HELPERS=maped-derive maped-up maped-down
CONF=maped.conf
RCSCRIPT=maped
MAN=maped.8

.PHONY: all test pf-test metrics-test install install-bin install-conf install-rc install-man metrics-install uninstall

all:
	@echo "Run 'make install' as root to install MAP-E CE maped."

test:
	perl tests/maped.t
	sh tests/maped-up-test.sh
	sh tests/run.sh
	$(MAKE) metrics-test

pf-test:
	perl tests/maped.t
	sh tests/pf-nat-test.sh "$(OPENBSD_SRC)"
	sh tests/pf-mape-validate-test.sh "$(OPENBSD_SRC)"

metrics-test:
	sh tests/metrics-run.sh

install: install-bin install-conf install-rc install-man

install-bin:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(BINDIR)
	install -o $(OWNER) -g $(GROUP) -m $(BINMODE) maped/$(SCRIPT) $(DESTDIR)$(BINDIR)/$(SCRIPT)
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(LIBEXECDIR)
	for helper in $(HELPERS); do \
		install -o $(OWNER) -g $(GROUP) -m $(BINMODE) maped/$$helper $(DESTDIR)$(LIBEXECDIR)/$$helper; \
	done

	install -o $(OWNER) -g $(GROUP) -m 444 maped/Maped.pm $(DESTDIR)$(LIBEXECDIR)/Maped.pm

install-conf:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(SYSCONFDIR)
	@if [ ! -f "$(DESTDIR)$(SYSCONFDIR)/$(CONF)" ]; then \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) maped/etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF)"; \
	else \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) maped/etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
		echo "$(DESTDIR)$(SYSCONFDIR)/$(CONF) exists; installed sample as $(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
	fi

install-rc:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(RCDIR)
	install -o $(OWNER) -g $(GROUP) -m $(RCMODE) maped/rc.d/$(RCSCRIPT) $(DESTDIR)$(RCDIR)/$(RCSCRIPT)

install-man:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(MANDIR)
	install -o $(OWNER) -g $(GROUP) -m $(MANMODE) maped/$(MAN) $(DESTDIR)$(MANDIR)/$(MAN)

metrics-install:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(BINDIR)
	install -o $(OWNER) -g $(GROUP) -m $(BINMODE) metrics/$(METRICS) $(DESTDIR)$(BINDIR)/$(METRICS)

uninstall:
	rm -f $(DESTDIR)$(LIBEXECDIR)/Maped.pm
	rm -f $(DESTDIR)$(BINDIR)/$(SCRIPT)
	rm -f $(DESTDIR)$(BINDIR)/$(METRICS)
	for helper in $(HELPERS); do \
		rm -f $(DESTDIR)$(LIBEXECDIR)/$$helper; \
	done
	rm -f $(DESTDIR)$(RCDIR)/$(RCSCRIPT)
	rm -f $(DESTDIR)$(MANDIR)/$(MAN)
