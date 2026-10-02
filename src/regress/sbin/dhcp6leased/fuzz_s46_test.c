/*	$OpenBSD$ */

#include <sys/types.h>
#include <sys/mman.h>
#include <sys/socket.h>

#include <net/if.h>
#include <netinet/in.h>

#include <err.h>
#include <event.h>
#include <imsg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "log.h"
#include "dhcp6leased.h"

#define	FUZZ_ITERATIONS		50000
#define	FUZZ_MAX_LEN		1024
#define	MAX_MUTATIONS		32

static uint32_t	 fuzz_rand(void);
static void	 check_one(const uint8_t *, size_t);
static void	 check_result(const struct s46_mape *);
static void	 check_seed(const uint8_t *, size_t);
static void	 check_random_bytes(void);
static void	 check_random_options(void);
static void	 mutate_seed(const uint8_t *, size_t);

static uint32_t fuzz_state = 0x46e7c0de;
static uint8_t *fuzz_area, *fuzz_guard;
static size_t fuzz_pagesz;

static uint32_t
fuzz_rand(void)
{
	uint32_t x = fuzz_state;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	fuzz_state = x;
	return (x);
}

static void
check_result(const struct s46_mape *mape)
{
	size_t i;

	if (!mape->valid)
		errx(1, "accepted MAP-E state not marked valid");
	if (!mape->br_valid)
		errx(1, "accepted MAP-E state without BR");
	if (mape->rule_count == 0 || mape->rule_count > MAX_S46_RULES)
		errx(1, "accepted MAP-E state with invalid rule count");

	for (i = 0; i < mape->rule_count; i++) {
		if (!mape->rules[i].valid)
			errx(1, "accepted MAP-E state with invalid rule");
		if (mape->rules[i].ea_len > 48 ||
		    mape->rules[i].prefix4_len > 32 ||
		    mape->rules[i].prefix6_len > 128)
			errx(1, "accepted MAP-E state with invalid prefix data");
		if (mape->rules[i].portparams.valid &&
		    (mape->rules[i].portparams.offset > 15 ||
		    mape->rules[i].portparams.psid_len > 16 ||
		    mape->rules[i].portparams.offset +
		    mape->rules[i].portparams.psid_len > 16))
			errx(1, "accepted MAP-E state with invalid portparams");
	}

	for (; i < MAX_S46_RULES; i++) {
		if (mape->rules[i].valid)
			errx(1, "accepted MAP-E state leaked extra rule");
	}
}

static void
check_one(const uint8_t *buf, size_t len)
{
	struct s46_mape mape;
	uint8_t sentinel[sizeof(mape)];
	uint8_t *p;
	int ret;

	if (len > FUZZ_MAX_LEN || len > fuzz_pagesz)
		errx(1, "bad fuzz length");

	memset(fuzz_area, 0xa5, fuzz_pagesz);
	p = fuzz_guard - len;
	if (len > 0)
		memcpy(p, buf, len);

	memset(sentinel, 0xa5, sizeof(sentinel));
	memset(&mape, 0xa5, sizeof(mape));
	ret = parse_s46_mape_options(p, len, &mape);
	if (ret == 0)
		check_result(&mape);
	else if (memcmp(&mape, sentinel, sizeof(mape)) != 0)
		errx(1, "rejected MAP-E input changed output state");
}

static void
check_seed(const uint8_t *buf, size_t len)
{
	size_t i;

	check_one(buf, len);
	for (i = 0; i <= len; i++)
		check_one(buf, i);
}

static void
mutate_seed(const uint8_t *seed, size_t seedlen)
{
	uint8_t buf[FUZZ_MAX_LEN];
	size_t i, len, mutations, pos;

	len = seedlen;
	if (len > sizeof(buf))
		len = sizeof(buf);
	memcpy(buf, seed, len);

	if ((fuzz_rand() & 3) == 0)
		len = fuzz_rand() % (len + 1);

	mutations = 1 + (fuzz_rand() % MAX_MUTATIONS);
	for (i = 0; i < mutations; i++) {
		if (len == 0 || ((fuzz_rand() & 7) == 0 &&
		    len < sizeof(buf))) {
			buf[len++] = fuzz_rand() & 0xff;
			continue;
		}
		pos = fuzz_rand() % len;
		buf[pos] ^= 1U << (fuzz_rand() & 7);
	}
	check_one(buf, len);
}

static void
check_random_bytes(void)
{
	uint8_t buf[FUZZ_MAX_LEN];
	size_t i, len;

	for (i = 0; i < FUZZ_ITERATIONS; i++) {
		len = fuzz_rand() % sizeof(buf);
		for (size_t j = 0; j < len; j++)
			buf[j] = fuzz_rand() & 0xff;
		check_one(buf, len);
	}
}

static void
check_random_options(void)
{
	uint8_t buf[FUZZ_MAX_LEN];
	size_t i, len, optlen, remain;
	uint16_t code, nlen;

	for (i = 0; i < FUZZ_ITERATIONS; i++) {
		len = 0;
		while (len + sizeof(struct dhcp_option_hdr) < sizeof(buf) &&
		    (fuzz_rand() & 3) != 0) {
			remain = sizeof(buf) - len -
			    sizeof(struct dhcp_option_hdr);
			optlen = fuzz_rand() % (remain + 1);
			code = htons(fuzz_rand() % 128);
			nlen = htons(optlen);
			memcpy(buf + len, &code, sizeof(code));
			len += sizeof(code);
			memcpy(buf + len, &nlen, sizeof(nlen));
			len += sizeof(nlen);
			for (size_t j = 0; j < optlen; j++)
				buf[len + j] = fuzz_rand() & 0xff;
			len += optlen;
		}
		check_one(buf, len);
	}
}

int
main(void)
{
	static const uint8_t valid_mape[] = {
	    0x00, 0x5a, 0x00, 0x10,
	    0x20, 0x01, 0x0d, 0xb8, 0xff, 0xff, 0x00, 0x00,
	    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
	    0x00, 0x59, 0x00, 0x17,
	    0x00, 0x10, 0x18, 0xc0, 0x00, 0x02, 0x7b, 0x38,
	    0x20, 0x01, 0x0d, 0xb8, 0x01, 0x00, 0x00,
	    0x00, 0x5d, 0x00, 0x04, 0x06, 0x08, 0x2a, 0x00,
	};
	static const uint8_t cosmote_mape[] = {
	    0x00, 0x59, 0x00, 0x16,
	    0x00, 0x0e, 0x18, 0x57, 0xca, 0x3a, 0x00, 0x2a,
	    0x2a, 0x02, 0x05, 0x86, 0x62, 0x00,
	    0x00, 0x5d, 0x00, 0x04, 0x06, 0x00, 0x00, 0x00,
	    0x00, 0x5a, 0x00, 0x10,
	    0x2a, 0x02, 0x05, 0x86, 0x00, 0x00, 0x00, 0x00,
	    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x06,
	};
	static const uint8_t multi_mape[] = {
	    0x00, 0x5a, 0x00, 0x10,
	    0x20, 0x01, 0x0d, 0xb8, 0xff, 0xff, 0x00, 0x00,
	    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
	    0x00, 0x59, 0x00, 0x17,
	    0x00, 0x10, 0x18, 0xc0, 0x00, 0x02, 0x7b, 0x38,
	    0x20, 0x01, 0x0d, 0xb8, 0x01, 0x00, 0x00,
	    0x00, 0x5d, 0x00, 0x04, 0x06, 0x08, 0x2a, 0x00,
	    0x00, 0x59, 0x00, 0x17,
	    0x80, 0x10, 0x18, 0xc6, 0x33, 0x64, 0x00, 0x38,
	    0x20, 0x01, 0x0d, 0xb8, 0x02, 0x00, 0x00,
	    0x00, 0x5d, 0x00, 0x04, 0x04, 0x06, 0x44, 0x00,
	};

	fuzz_pagesz = getpagesize();
	if (FUZZ_MAX_LEN > fuzz_pagesz)
		errx(1, "FUZZ_MAX_LEN exceeds page size");
	fuzz_area = mmap(NULL, fuzz_pagesz * 2, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	if (fuzz_area == MAP_FAILED)
		err(1, "mmap");
	fuzz_guard = fuzz_area + fuzz_pagesz;
	if (mprotect(fuzz_guard, fuzz_pagesz, PROT_NONE) == -1)
		err(1, "mprotect");

	/* A well-formed future TLV must not invalidate a usable rule. */
	{
		static const uint8_t extra[] = {
		    0x12, 0x34, 0x00, 0x02, 0xaa, 0xbb
		};
		uint8_t extended[sizeof(valid_mape) + sizeof(extra)];
		struct s46_mape baseline, parsed;

		if (parse_s46_mape_options((uint8_t *)valid_mape,
		    sizeof(valid_mape), &baseline) != 0)
			errx(1, "valid MAP-E seed rejected");
		memcpy(extended, valid_mape, sizeof(valid_mape));
		memcpy(extended + sizeof(valid_mape), extra, sizeof(extra));
		if (parse_s46_mape_options(extended, sizeof(extended),
		    &parsed) != 0 || parsed.rule_count != baseline.rule_count ||
		    !parsed.rules[0].portparams.valid)
			errx(1, "unknown MAP-E container TLV rejected");
		/* Increase the rule length to place the TLV inside the rule. */
		extended[23] += sizeof(extra);
		if (parse_s46_mape_options(extended, sizeof(extended),
		    &parsed) != 0 || parsed.rule_count != baseline.rule_count ||
		    !parsed.rules[0].portparams.valid)
			errx(1, "unknown MAP-E rule TLV rejected");
		/* Even an unknown TLV must still be fully bounded. */
		extended[sizeof(valid_mape) + 2] = 0xff;
		if (parse_s46_mape_options(extended, sizeof(extended),
		    &parsed) == 0)
			errx(1, "truncated unknown MAP-E TLV accepted");
	}

	check_seed(valid_mape, sizeof(valid_mape));
	check_seed(cosmote_mape, sizeof(cosmote_mape));
	check_seed(multi_mape, sizeof(multi_mape));

	for (size_t i = 0; i < FUZZ_ITERATIONS / 10; i++) {
		mutate_seed(valid_mape, sizeof(valid_mape));
		mutate_seed(cosmote_mape, sizeof(cosmote_mape));
		mutate_seed(multi_mape, sizeof(multi_mape));
	}
	check_random_bytes();
	check_random_options();

	return (0);
}

void
log_warnx(const char *fmt, ...)
{
	(void)fmt;
}

void
log_debug(const char *fmt, ...)
{
	(void)fmt;
}
