/*	$OpenBSD$ */

/*
 * Copyright (c) 2026 Panagiotis Atmatzidis <atma@convalesco.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>
#include <sys/socket.h>

#include <net/if.h>
#include <netinet/in.h>

#include <arpa/inet.h>

#include <event.h>
#include <imsg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "log.h"
#include "dhcp6leased.h"

static void	 mask_in_addr(struct in_addr *, uint8_t);
static void	 mask_in6_addr(struct in6_addr *, uint8_t);
static int	 parse_s46_rule(uint8_t *, size_t, struct s46_rule *);
static int	 parse_s46_rule_options(uint8_t *, size_t, struct s46_rule *);

static void
mask_in_addr(struct in_addr *addr, uint8_t prefix_len)
{
	uint32_t	 a, mask;

	a = ntohl(addr->s_addr);
	if (prefix_len == 0)
		mask = 0;
	else
		mask = 0xffffffffU << (32 - prefix_len);
	addr->s_addr = htonl(a & mask);
}

static void
mask_in6_addr(struct in6_addr *addr, uint8_t prefix_len)
{
	uint8_t	 mask;
	int	 i;

	for (i = 0; i < 16; i++) {
		if (prefix_len >= 8) {
			mask = 0xff;
			prefix_len -= 8;
		} else if (prefix_len > 0) {
			mask = 0xff << (8 - prefix_len);
			prefix_len = 0;
		} else
			mask = 0;
		addr->s6_addr[i] &= mask;
	}
}

int
parse_s46_mape_options(uint8_t *p, size_t len, struct s46_mape *mape)
{
	struct dhcp_option_hdr	 opt_hdr;
	struct s46_mape		 nmape;

	memset(&nmape, 0, sizeof(nmape));
	while (len >= sizeof(struct dhcp_option_hdr)) {
		memcpy(&opt_hdr, p, sizeof(opt_hdr));
		opt_hdr.code = ntohs(opt_hdr.code);
		opt_hdr.len = ntohs(opt_hdr.len);
		p += sizeof(opt_hdr);
		len -= sizeof(opt_hdr);

		if (len < opt_hdr.len) {
			log_warnx("%s: malformed S46 MAP-E container",
			    __func__);
			return (-1);
		}

		switch (opt_hdr.code) {
		case DHO_S46_BR:
			if (opt_hdr.len != sizeof(nmape.br)) {
				log_warnx("%s: invalid S46 BR length: %u",
				    __func__, opt_hdr.len);
				return (-1);
			}
			/* RFC 7598 permits several BRs; use the first one. */
			if (nmape.br_valid)
				break;
			memcpy(&nmape.br, p, sizeof(nmape.br));
			nmape.br_valid = 1;
			break;
		case DHO_S46_RULE:
			if (nmape.rule_count >= nitems(nmape.rules)) {
				log_warnx("%s: too many S46 MAP-E rules",
				    __func__);
				return (-1);
			}
			if (parse_s46_rule(p, opt_hdr.len,
			    &nmape.rules[nmape.rule_count]) != 0)
				return (-1);
			nmape.rule_count++;
			break;
		default:
			/*
			 * RFC 7598 permits unknown sub-options in
			 * extensible MAP-E containers. The TLV length
			 * has already been checked against the remaining
			 * buffer, so skip it without interpreting it.
			 * Reject malformed known BR/rule options above;
			 * do not let optional future extensions make a
			 * valid provisioning response unusable.
			 * Keep the BR and rule requirements below.
			 */
			log_debug("%s: ignoring unknown MAP-E sub-option: "
			    "%u", __func__, opt_hdr.code);
			break;
		}

		p += opt_hdr.len;
		len -= opt_hdr.len;
	}
	if (len != 0 || !nmape.br_valid || nmape.rule_count == 0) {
		log_warnx("%s: incomplete S46 MAP-E container", __func__);
		return (-1);
	}

	nmape.valid = 1;
	*mape = nmape;
	return (0);
}

static int
parse_s46_rule(uint8_t *p, size_t len, struct s46_rule *rule)
{
	struct s46_rule		 nrule;
	size_t			 prefix6_bytes;

	memset(&nrule, 0, sizeof(nrule));
	if (len < 8) {
		log_warnx("%s: S46 rule too short", __func__);
		return (-1);
	}

	nrule.flags = p[0];
	nrule.ea_len = p[1];
	nrule.prefix4_len = p[2];
	memcpy(&nrule.prefix4, p + 3, sizeof(nrule.prefix4));
	nrule.prefix6_len = p[7];
	p += 8;
	len -= 8;

	if (nrule.ea_len > 48 || nrule.prefix4_len > 32 ||
	    nrule.prefix6_len > 128) {
		log_warnx("%s: invalid S46 rule parameters", __func__);
		return (-1);
	}

	prefix6_bytes = (nrule.prefix6_len + 7) / 8;
	if (len < prefix6_bytes) {
		log_warnx("%s: truncated S46 IPv6 prefix", __func__);
		return (-1);
	}
	memcpy(&nrule.prefix6, p, prefix6_bytes);
	p += prefix6_bytes;
	len -= prefix6_bytes;

	mask_in_addr(&nrule.prefix4, nrule.prefix4_len);
	mask_in6_addr(&nrule.prefix6, nrule.prefix6_len);

	if (parse_s46_rule_options(p, len, &nrule) != 0)
		return (-1);

	nrule.valid = 1;
	*rule = nrule;
	return (0);
}

static int
parse_s46_rule_options(uint8_t *p, size_t len, struct s46_rule *rule)
{
	struct dhcp_option_hdr	 opt_hdr;
	uint16_t		 psid;

	while (len >= sizeof(struct dhcp_option_hdr)) {
		memcpy(&opt_hdr, p, sizeof(opt_hdr));
		opt_hdr.code = ntohs(opt_hdr.code);
		opt_hdr.len = ntohs(opt_hdr.len);
		p += sizeof(opt_hdr);
		len -= sizeof(opt_hdr);

		if (len < opt_hdr.len) {
			log_warnx("%s: malformed S46 rule option", __func__);
			return (-1);
		}

		switch (opt_hdr.code) {
		case DHO_S46_PORTPARAMS:
			if (opt_hdr.len != 4) {
				log_warnx("%s: invalid S46 portparams length: "
				    "%u", __func__, opt_hdr.len);
				return (-1);
			}
			if (rule->portparams.valid) {
				log_warnx("%s: duplicate S46 portparams",
				    __func__);
				return (-1);
			}
			if (p[0] > 15 || p[1] > 16 || p[0] + p[1] > 16) {
				log_warnx("%s: invalid S46 portparams", __func__);
				return (-1);
			}
			memcpy(&psid, p + 2, sizeof(psid));
			rule->portparams.offset = p[0];
			rule->portparams.psid_len = p[1];
			/*
			 * RFC 7598: a zero PSID length means the encoded PSID
			 * field is ignored. It does not by itself rule out
			 * address sharing; MAP-E may derive the PSID from the
			 * EA bits as described in RFC 7597.
			 *
			 * Keep portparams.valid even in this case: the option
			 * still supplies an offset, unlike an absent option.
			 */
			if (p[1] == 0)
				rule->portparams.psid = 0;
			else
				rule->portparams.psid = ntohs(psid) >>
				    (16 - p[1]);
			rule->portparams.valid = 1;
			break;
		default:
			log_debug("%s: ignoring unknown S46 rule sub-option: "
			    "%u", __func__, opt_hdr.code);
			break;
		}

		p += opt_hdr.len;
		len -= opt_hdr.len;
	}
	if (len != 0) {
		log_warnx("%s: trailing malformed S46 rule option", __func__);
		return (-1);
	}
	return (0);
}
