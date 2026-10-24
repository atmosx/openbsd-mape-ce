OPENBSD_SRC?=src

.PHONY: all test
all:
	@echo "See ../README.md for patch installation and tests/OPENBSD79.md for validation."

test:
	sh tests/pf-nat-test.sh "$(OPENBSD_SRC)"
	sh tests/pf-mape-validate-test.sh "$(OPENBSD_SRC)"
