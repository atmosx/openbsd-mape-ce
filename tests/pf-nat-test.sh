#!/bin/sh
set -eu

src=${1:-/usr/src}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mape-pf-test.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/test.c" <<'EOF'
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define INET6 1
#define ICMP_ECHO 8
#define ICMP6_ECHO_REQUEST 128
#define PF_SN_NAT 0
#define PF_IN 1
#define PF_OUT 2
struct pf_addr { int value; };
struct pf_src_node { int unused; };
struct pf_state_key_cmp { int unused; };
struct pf_pdesc {
	int dir, sidx, didx, naf, proto;
	uint16_t ndport;
	struct pf_addr nsaddr;
};
struct pf_rule {
	struct {
		struct { uint8_t offset, psidlen; uint16_t psid; } mape;
	} nat;
};
static unsigned calls, expected_calls;
static int map_fail, exhausted;
static uint16_t seen_low, seen_high;
static unsigned char visited[32768];
static int
pf_map_addr(int af, struct pf_rule *r, struct pf_addr *src,
    struct pf_addr *dst, struct pf_addr *init, struct pf_src_node **sn,
    void *pool, int type)
{
	(void)af; (void)r; (void)src; (void)init;
	(void)sn; (void)pool; (void)type;
	calls++;
	dst->value = 42;
	return map_fail;
}
EOF

awk '
/^pf_get_sport_range\(/ { active = 1; print "static int" }
active && /^\tdo \{/ {
	print "\tseen_low = low; seen_high = high; return (2);"
	print "}"
	found = 1; exit
}
active { print }
END { if (!found) exit 1 }
' "$src/sys/net/pf_lb.c" >> "$tmp/test.c"

cat >> "$tmp/test.c" <<'EOF'
static int
check_range(struct pf_pdesc *pd, struct pf_rule *r, struct pf_addr *addr,
    uint16_t *port, uint16_t low, uint16_t high, struct pf_src_node **sn)
{
	unsigned shift = 16 - r->nat.mape.offset - r->nat.mape.psidlen;
	unsigned a = low >> (16 - r->nat.mape.offset);
	(void)pd; (void)addr; (void)port; (void)sn;
	assert(a != 0 && a < 32768 && !visited[a]);
	visited[a] = 1;
	assert(((low >> shift) & ((1U << r->nat.mape.psidlen) - 1)) == r->nat.mape.psid);
	assert(high == (low | ((1U << shift) - 1)));
	assert(++calls <= expected_calls);
	return exhausted == 2 ? -1 : exhausted;
}
#define pf_get_sport_range check_range
EOF

awk '
/^pf_get_sport_mape\(/ { active = 1; print "static int" }
active { print }
active && /^}/ { found = 1; exit }
END { if (!found) exit 1 }
' "$src/sys/net/pf_lb.c" >> "$tmp/test.c"

cat >> "$tmp/test.c" <<'EOF'
#undef pf_get_sport_range
int
main(void)
{
	struct pf_pdesc pd = {0};
	struct pf_rule r = {0};
	struct pf_addr addr = {0};
	struct pf_src_node *sn = NULL;
	uint16_t port = 0;
	int family, mape, offset, length, edge, mode;

	for (family = 0; family < 2; family++) {
		pd.proto = family ? IPPROTO_ICMPV6 : IPPROTO_ICMP;
		for (mape = 0; mape < 2; mape++) {
			r.nat.mape.offset = mape ? 6 : 0;
			pd.ndport = htons(3);
			calls = 0; addr.value = 0;
			assert(pf_get_sport_range(&pd, &r, &addr, &port, 1024, 1039, &sn) == 0);
			assert(calls == 1 && addr.value == 42);
			map_fail = 1;
			assert(pf_get_sport_range(&pd, &r, &addr, &port, 1024, 1039, &sn) == -1);
			map_fail = 0;
			pd.ndport = htons(family ? ICMP6_ECHO_REQUEST : ICMP_ECHO);
			assert(pf_get_sport_range(&pd, &r, &addr, &port, 1024, 1039, &sn) == 2);
			assert(seen_low == (mape ? 1024 : 1));
			assert(seen_high == (mape ? 1039 : 65535));
		}
	}
	for (offset = 1; offset <= 15; offset++) {
		for (length = 1; length <= 16 - offset; length++) {
			for (edge = 0; edge < 2; edge++) {
				r.nat.mape.offset = offset;
				r.nat.mape.psidlen = length;
				r.nat.mape.psid = edge ? (1U << length) - 1 : 0;
				for (mode = 0; mode < 3; mode++) {
					calls = 0; exhausted = mode;
					expected_calls = mode == 1 ? (1U << offset) - 1 : 1;
					memset(visited, 0, sizeof(visited));
					assert(pf_get_sport_mape(&pd, &r, &addr, &port, &sn) == (mode != 0));
					assert(calls == expected_calls);
				}
			}
		}
	}
	return 0;
}
EOF

${CC:-cc} ${CFLAGS:-} -Wall -Wextra -Wno-unused-variable -Wno-unused-parameter \
    -o "$tmp/test" "$tmp/test.c"
"$tmp/test"
printf '%s\n' 'ok - PF ICMP address mapping and MAP-E allocation boundaries/exhaustion/address failure'
