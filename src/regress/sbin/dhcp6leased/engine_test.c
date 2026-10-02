/*	$OpenBSD$ */

/* Exercise the engine's packet parser without sockets or state timers. */
#include <sys/types.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <assert.h>
#include <event.h>
#include <imsg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vis.h>

#include "dhcp6leased.h"
#include "engine_types.h"

static struct dhcp6leased_conf conf;
static struct dhcp6leased_conf *engine_conf = &conf;
static struct iface_conf iface_conf;
static struct dhcp_duid duid;

void parse_dhcp(struct dhcp6leased_iface *, struct imsg_dhcp *);
int parse_ia_pd_options(uint8_t *, size_t, struct prefix *);
int prefixcmp(struct prefix *, struct prefix *, int);
void in6_prefixlen2mask(struct in6_addr *, int);
#define log_warn log_warnx
#define fatalx fatal

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

int
log_getverbose(void)
{
	return (0);
}

static void
fatal(const char *fmt, ...)
{
	(void)fmt;
	abort();
}

static const char *
dhcp_duid2str(int len, uint8_t *p)
{
	(void)len;
	(void)p;
	return ("server");
}

static const char *
dhcp_status2str(int code)
{
	(void)code;
	return ("status");
}

const char *
dhcp_message_type2str(int code)
{
	(void)code;
	return ("message");
}

static const char *
dhcp_option_type2str(int code)
{
	(void)code;
	return ("option");
}

struct iface_conf *
find_iface_conf(struct iface_conf_head *head, char *name)
{
	(void)head;
	(void)name;
	return (&iface_conf);
}

static void
state_transition(struct dhcp6leased_iface *iface, enum if_state state)
{
	iface->state = state;
}

#include "engine_parse.c"

int
main(void)
{
	struct dhcp6leased_iface iface;
	struct imsg_dhcp packet;
	struct iface_ia_conf ia_conf;
	struct dhcp_option_hdr opt;
	struct dhcp_iapd iapd;
	struct dhcp_iaprefix prefix;
	size_t len;
	int scenario;
	/* REPLY, server ID, then MAP-E with one BR and a /42 rule. */
	static const uint8_t reply[] = {
	    7, 0, 0, 0, 0, 2, 0, 3, 0, 1, 1,
	    0, 94, 0, 38,
	    0, 90, 0, 16,
	    0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0,
	    0, 0, 0, 0, 0, 0, 0, 1,
	    0, 89, 0, 14,
	    0, 14, 24, 192, 0, 2, 0, 42,
	    0x20, 1, 0x0d, 0xb8, 0, 0
	};
	int enabled;

	SIMPLEQ_INIT(&iface_conf.iface_ia_list);
	memset(&ia_conf, 0, sizeof(ia_conf));
	ia_conf.prefix_len = 64;
	iface_conf.ia_count = 1;
	SIMPLEQ_INSERT_TAIL(&iface_conf.iface_ia_list, &ia_conf, entry);
	for (enabled = 0; enabled < 2; enabled++) {
		memset(&iface, 0, sizeof(iface));
		memset(&packet, 0, sizeof(packet));
		iface.if_index = if_nametoindex("lo0");
		assert(iface.if_index != 0);
		iface.state = IF_REQUESTING;
		iface_conf.request_mape = enabled;
		memcpy(packet.packet, reply, sizeof(reply));
		len = sizeof(reply);
		memset(&iapd, 0, sizeof(iapd));
		memset(&prefix, 0, sizeof(prefix));
		prefix.prefix_len = 56;
		prefix.vltime = htonl(600);
		prefix.pltime = htonl(300);
		assert(inet_pton(AF_INET6, "2001:db8:100::",
		    &prefix.prefix) == 1);
		opt.code = htons(DHO_IA_PD);
		opt.len = htons(sizeof(iapd) + sizeof(opt) + sizeof(prefix));
		memcpy(packet.packet + len, &opt, sizeof(opt));
		len += sizeof(opt);
		memcpy(packet.packet + len, &iapd, sizeof(iapd));
		len += sizeof(iapd);
		opt.code = htons(DHO_IA_PREFIX);
		opt.len = htons(sizeof(prefix));
		memcpy(packet.packet + len, &opt, sizeof(opt));
		len += sizeof(opt);
		memcpy(packet.packet + len, &prefix, sizeof(prefix));
		packet.len = len + sizeof(prefix);
		parse_dhcp(&iface, &packet);
		assert(iface.state == IF_BOUND);
		assert(iface.mape.valid == enabled);
	}

	/* Retain malformed renewal data only for the same, unexpired lease. */
	for (scenario = 0; scenario < 5; scenario++) {
		packet.packet[18] = 16;
		iface.state = IF_REQUESTING;
		parse_dhcp(&iface, &packet);
		assert(iface.mape.valid);
		memcpy(iface.pds, iface.new_pds, sizeof(iface.pds));
		iface.state = IF_RENEWING;
		packet.packet[18] = 15; /* Invalid BR length inside a valid TLV. */
		switch (scenario) {
		case 1:
			iface.pds[0].prefix.s6_addr[7] ^= 1;
			break;
		case 2:
			iface.serverid[2] ^= 1;
			break;
		case 3:
			iface.request_time.tv_sec -= 601;
			break;
		case 4:
			iface.state = IF_REBOOTING;
			break;
		}
		parse_dhcp(&iface, &packet);
		assert(iface.state == IF_BOUND);
		assert(iface.mape.valid == (scenario == 0));
	}
	return (0);
}
