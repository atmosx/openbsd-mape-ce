#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../mape-scripts/mape-metrics";

my %conf = MapeMetrics::parse_conf_text(<<'CONF');
# comment
WAN_IF="pppoe0"
GIF_IF='gif0'
VLAN_IF=vlan835 # inline comment
LAN_NET="{ 192.168.121.0/24, 192.168.122.0/24 }"
export MAP_IPV6_PLEN="42"
CONF

is($conf{WAN_IF}, "pppoe0", "double-quoted config value");
is($conf{GIF_IF}, "gif0", "single-quoted config value");
is($conf{VLAN_IF}, "vlan835", "unquoted config value with inline comment");
is($conf{LAN_NET}, "{ 192.168.121.0/24, 192.168.122.0/24 }", "space-preserving config value");
is($conf{MAP_IPV6_PLEN}, "42", "export prefix is accepted");

my %derive = MapeMetrics::parse_derive_output(<<'DERIVE');
PD_PREFIX='2a02:586:6201:2400::/56'
CE_IPV6='2a02:586:6201:2400:57ca:3a04::'
MAPE_IPV4='87.202.58.4'
PSID_OFFSET='6'
PSID_LEN='6'
PSID='4'
DERIVE

is($derive{CE_IPV6}, "2a02:586:6201:2400:57ca:3a04::", "derive CE IPv6 parsed");
is($derive{MAPE_IPV4}, "87.202.58.4", "derive MAP-E IPv4 parsed");
is($derive{PSID}, "4", "derive PSID parsed");

my $portset = MapeMetrics::mape_portset(6, 6, 4);
is($portset->{shift}, 4, "portset shift");
is($portset->{block_size}, 16, "portset block size");
is($portset->{range_count}, 64, "portset range count");
is($portset->{ports_total}, 1024, "total ports");
is($portset->{ports_usable_ge1024}, 1008, "usable ports above privileged range");
is_deeply($portset->{ranges}[0], [64, 79], "first raw port range");
is_deeply($portset->{usable_ranges}[0], [1088, 1103], "first usable port range");

my %gif = MapeMetrics::parse_ifconfig(<<'IFCONFIG');
gif0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1452
	index 7 priority 0 llprio 3
	groups: gif
	tunnel inet6 2a02:586:6201:2400:57ca:3a04:: --> 2a02:586::406 ttl 64
	inet 87.202.58.4 --> 0.0.0.1 netmask 0xffffffff
	inet6 fe80::1%gif0 prefixlen 64 scopeid 0x7
IFCONFIG

is($gif{name}, "gif0", "ifconfig interface name");
is($gif{mtu}, 1452, "ifconfig mtu");
is($gif{up}, 1, "ifconfig UP flag");
is($gif{running}, 1, "ifconfig RUNNING flag");
is($gif{tunnel_src}, "2a02:586:6201:2400:57ca:3a04::", "gif tunnel source");
is($gif{tunnel_dst}, "2a02:586::406", "gif tunnel destination");
is_deeply($gif{inet}, ["87.202.58.4"], "IPv4 address parsed");
is_deeply($gif{inet6}, ["fe80::1%gif0/64"], "IPv6 address parsed");

my %pppoe = MapeMetrics::parse_ifconfig(<<'PPPOE');
pppoe0: flags=8851<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1492
	index 11 priority 0 llprio 3
	dev: vlan835 state: session
	sid: 0x1234 PADI retries: 0 PADR retries: 0 time: 00:10:00
	sppp: phase network authproto pap authname "example"
	groups: pppoe egress
PPPOE

is($pppoe{pppoe_dev}, "vlan835", "pppoe lower device");
is($pppoe{pppoe_state}, "session", "pppoe state");
is($pppoe{pppoe_sid}, "0x1234", "pppoe session id");
is($pppoe{sppp_phase}, "network", "sppp phase");
is_deeply($pppoe{groups}, ["pppoe", "egress"], "groups parsed");

my %route = MapeMetrics::parse_route_get(<<'ROUTE');
   route to: default
destination: default
       mask: default
    gateway: fe80::1%pppoe0
  interface: pppoe0
 if address: fe80::2%pppoe0
   priority: 8
ROUTE

is($route{destination}, "default", "route destination");
is($route{gateway}, "fe80::1%pppoe0", "route gateway");
is($route{interface}, "pppoe0", "route interface");
is($route{if_address}, "fe80::2%pppoe0", "route if address key normalized");

my %netstat = MapeMetrics::parse_netstat_interface(<<'NETSTAT', "vlan835");
Name    Mtu   Network     Address              Ipkts Ierrs    Ibytes    Opkts Oerrs    Obytes  Colls
vlan835 1500  <Link>      00:11:22:33:44:55     1000     2    123456      900     1     654321      0
NETSTAT

is($netstat{ipkts}, 1000, "netstat input packets parsed");
is($netstat{ierrs}, 2, "netstat input errors parsed");
is($netstat{ibytes}, 123456, "netstat input bytes parsed");
is($netstat{opkts}, 900, "netstat output packets parsed");
is($netstat{oerrs}, 1, "netstat output errors parsed");
is($netstat{obytes}, 654321, "netstat output bytes parsed");

my @defaults = MapeMetrics::parse_netstat_default_routes(<<'ROUTES');
Destination        Gateway            Flags   Refs      Use   Mtu  Prio Iface
default            fe80::1%pppoe0     UGS        0        1     -     8 pppoe0
2001:db8::/32      link#4             UCn        0        0     -     4 vlan835
ROUTES

is_deeply(\@defaults, ["fe80::1%pppoe0"], "IPv6 default route gateway parsed");

my %ndp = MapeMetrics::parse_ndp_counts(<<'NDP');
Neighbor                             Linklayer Address  Netif Expire    S Flags
fe80::1%pppoe0                       00:11:22:33:44:55 pppoe0 23h59m   R R
2a02:586::406                        66:77:88:99:aa:bb vlan835 12m     S R
NDP

is($ndp{pppoe0}, 1, "ndp pppoe0 neighbor count");
is($ndp{vlan835}, 1, "ndp vlan835 neighbor count");

done_testing();
