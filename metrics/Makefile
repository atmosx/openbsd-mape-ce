PREFIX?=/usr/local
BINDIR?=$(PREFIX)/sbin
OWNER?=root
GROUP?=wheel
BINMODE?=755

.PHONY: all test install uninstall
all:
	@echo "Run 'make install' as root to install the optional metrics exporter."

test:
	sh tests/run.sh

install:
	install -d -o $(OWNER) -g $(GROUP) -m 755 $(DESTDIR)$(BINDIR)
	install -o $(OWNER) -g $(GROUP) -m $(BINMODE) mape-prometheus-metrics $(DESTDIR)$(BINDIR)/mape-prometheus-metrics

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/mape-prometheus-metrics
