#	$OpenBSD$

PROGS=	parse_lease_test fuzz_s46_test engine_test
SRCS_parse_lease_test=	parse_lease_test.c parse_lease.c s46.c
SRCS_fuzz_s46_test=	fuzz_s46_test.c s46.c
SRCS_engine_test=	engine_test.c s46.c

.PATH: ${.CURDIR}/../../../sbin/dhcp6leased
CFLAGS+= -I${.CURDIR}/../../../sbin/dhcp6leased
CLEANFILES+= parse_lease.c engine_types.h engine_parse.c

engine_test.o: engine_types.h engine_parse.c

engine_types.h: ${.CURDIR}/../../../sbin/dhcp6leased/engine.c
	awk '/^enum if_state \{/ || /^struct dhcp6leased_iface \{/ { p=1 } \
	    p { print } /^};/ { p=0 }' ${.ALLSRC} > ${.TARGET}

engine_parse.c: ${.CURDIR}/../../../sbin/dhcp6leased/engine.c
	awk '/^parse_dhcp\(/ || /^in6_prefixlen2mask\(/ { print "void"; p=1 } \
	    /^parse_ia_pd_options\(/ || /^prefixcmp\(/ { print "int"; p=1 } \
	    p { print } /^}/ { p=0 }' ${.ALLSRC} > ${.TARGET}

REGRESS_TARGETS+=	run-regress-engine_test
REGRESS_TARGETS+=	run-regress-parse_lease_test
REGRESS_TARGETS+=	run-regress-fuzz_s46_test
REGRESS_TARGETS+=	run-regress-fuzz_s46_test-malloc

parse_lease.c: ${.CURDIR}/../../../sbin/dhcp6leased/parse_lease.y
	yacc -ppl -o ${.TARGET} ${.ALLSRC}

run-regress-engine_test: engine_test
	./engine_test

run-regress-parse_lease_test: parse_lease_test
	./parse_lease_test

run-regress-fuzz_s46_test: fuzz_s46_test
	./fuzz_s46_test

run-regress-fuzz_s46_test-malloc: fuzz_s46_test
	env MALLOC_OPTIONS=S ./${.ALLSRC}

.include <bsd.regress.mk>
