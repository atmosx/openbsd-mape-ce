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
HELPERS=maped-derive maped-up maped-down maped-config maped-publish
CONF=maped.conf
RCSCRIPT=maped
MAN=maped.8

.PHONY: all test install install-bin install-conf install-rc install-man uninstall

all:
	@echo "Run 'make install' as root to install MAP-E CE maped."

install: install-bin install-conf install-rc install-man

install-bin:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(BINDIR)
	install -o $(OWNER) -g $(GROUP) -m $(BINMODE) bin/$(SCRIPT) $(DESTDIR)$(BINDIR)/$(SCRIPT)
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(LIBEXECDIR)
	for helper in $(HELPERS); do \
		install -o $(OWNER) -g $(GROUP) -m $(BINMODE) bin/$$helper $(DESTDIR)$(LIBEXECDIR)/$$helper; \
	done
	install -o $(OWNER) -g $(GROUP) -m 444 lib/Maped.pm $(DESTDIR)$(LIBEXECDIR)/Maped.pm

	install -o $(OWNER) -g $(GROUP) -m 444 lib/MapedStatus.pm $(DESTDIR)$(LIBEXECDIR)/MapedStatus.pm
	install -o $(OWNER) -g $(GROUP) -m 444 lib/MapedPublish.pm $(DESTDIR)$(LIBEXECDIR)/MapedPublish.pm

install-conf:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(SYSCONFDIR)
	@if [ ! -f "$(DESTDIR)$(SYSCONFDIR)/$(CONF)" ]; then \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF)"; \
	else \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
		echo "$(DESTDIR)$(SYSCONFDIR)/$(CONF) exists; installed sample as $(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
	fi

install-rc:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(RCDIR)
	install -o $(OWNER) -g $(GROUP) -m $(RCMODE) etc/rc.d/$(RCSCRIPT) $(DESTDIR)$(RCDIR)/$(RCSCRIPT)

install-man:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(MANDIR)
	install -o $(OWNER) -g $(GROUP) -m $(MANMODE) man/$(MAN) $(DESTDIR)$(MANDIR)/$(MAN)

uninstall:
	rm -f $(DESTDIR)$(LIBEXECDIR)/MapedPublish.pm
	rm -f $(DESTDIR)$(LIBEXECDIR)/MapedStatus.pm
	rm -f $(DESTDIR)$(LIBEXECDIR)/Maped.pm
	rm -f $(DESTDIR)$(BINDIR)/$(SCRIPT)
	for helper in $(HELPERS); do \
		rm -f $(DESTDIR)$(LIBEXECDIR)/$$helper; \
	done
	rm -f $(DESTDIR)$(RCDIR)/$(RCSCRIPT)
	rm -f $(DESTDIR)$(MANDIR)/$(MAN)

test:
	prove tests/*.t
	sh tests/maped-down-test.sh
	sh tests/maped-up-test.sh
	sh tests/run.sh
