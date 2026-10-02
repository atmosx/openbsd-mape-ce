#	$OpenBSD$

PROGS=	parse_lease_test fuzz_s46_test
SRCS_parse_lease_test=	parse_lease_test.c parse_lease.c s46.c
SRCS_fuzz_s46_test=	fuzz_s46_test.c s46.c

.PATH: ${.CURDIR}/../../../sbin/dhcp6leased
CFLAGS+= -I${.CURDIR}/../../../sbin/dhcp6leased
CLEANFILES+= parse_lease.c

REGRESS_TARGETS+=	run-regress-parse_lease_test
REGRESS_TARGETS+=	run-regress-fuzz_s46_test
REGRESS_TARGETS+=	run-regress-fuzz_s46_test-malloc

parse_lease.c: ${.CURDIR}/../../../sbin/dhcp6leased/parse_lease.y
	yacc -ppl -o ${.TARGET} ${.ALLSRC}

run-regress-parse_lease_test: parse_lease_test
	./parse_lease_test

run-regress-fuzz_s46_test: fuzz_s46_test
	./fuzz_s46_test

run-regress-fuzz_s46_test-malloc: fuzz_s46_test
	env MALLOC_OPTIONS=S ./${.ALLSRC}

.include <bsd.regress.mk>
