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
	for (enabled = 0; enabled < 2; enabled++) {
		memset(&iface, 0, sizeof(iface));
		memset(&packet, 0, sizeof(packet));
		iface.if_index = if_nametoindex("lo0");
		assert(iface.if_index != 0);
		iface.state = IF_REQUESTING;
		iface_conf.request_mape = enabled;
		memcpy(packet.packet, reply, sizeof(reply));
		packet.len = sizeof(reply);
		parse_dhcp(&iface, &packet);
		assert(iface.state == IF_BOUND);
		assert(iface.mape.valid == enabled);
	}
	return (0);
}
