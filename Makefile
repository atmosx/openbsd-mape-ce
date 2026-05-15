PREFIX?=/usr/local
BINDIR?=$(PREFIX)/sbin
SYSCONFDIR?=/etc
RCDIR?=/etc/rc.d

OWNER?=root
GROUP?=wheel
BINMODE?=755
CONFMODE?=600
RCMODE?=555

SCRIPTS=mape-derive mape-up mape-down mape-watch
CONF=mape.conf
RCSCRIPT=mape_watch

.PHONY: all install install-bin install-conf install-rc uninstall

all:
	@echo "Run 'make install' as root to install MAP-E CE scripts."

install: install-bin install-conf install-rc

install-bin:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(BINDIR)
	for script in $(SCRIPTS); do \
		install -o $(OWNER) -g $(GROUP) -m $(BINMODE) scripts/$$script $(DESTDIR)$(BINDIR)/$$script; \
	done

install-conf:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(SYSCONFDIR)
	@if [ ! -f "$(DESTDIR)$(SYSCONFDIR)/$(CONF)" ]; then \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) scripts/etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF)"; \
	else \
		install -o $(OWNER) -g $(GROUP) -m $(CONFMODE) scripts/etc/$(CONF) "$(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
		echo "$(DESTDIR)$(SYSCONFDIR)/$(CONF) exists; installed sample as $(DESTDIR)$(SYSCONFDIR)/$(CONF).sample"; \
	fi

install-rc:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(RCDIR)
	install -o $(OWNER) -g $(GROUP) -m $(RCMODE) scripts/rc.d/$(RCSCRIPT) $(DESTDIR)$(RCDIR)/$(RCSCRIPT)

uninstall:
	for script in $(SCRIPTS); do \
		rm -f $(DESTDIR)$(BINDIR)/$$script; \
	done
	rm -f $(DESTDIR)$(RCDIR)/$(RCSCRIPT)
