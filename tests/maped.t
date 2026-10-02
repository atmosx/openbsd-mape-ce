use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../maped";
use Maped qw(command status_text parse_lease complete_lease lease_text parse_config config_text live_lease effective_mtu has_ipv6 runtime_mismatch);
my ($rc, $out) = command(2, 1024, $^X, '-e', 'print "ok"');
is($rc, 0, 'successful child');
is($out, 'ok', 'capture output');
($rc, $out) = command(2, 1024, $^X, '-e', 'print "partial"; exit 3');
is(status_text($rc), 'exit 3', 'nonzero exit');
($rc, $out) = command(2, 1024, '/nonexistent/maped-command');
is($rc, -1, 'exec failure');
($rc, $out) = command(2, 1024, $^X, '-e', 'kill 15, $$');
is(status_text($rc), 'signal 15', 'signal is not exit zero');
($rc, $out) = command(0.2, 1024, $^X, '-e', 'sleep 10');
is($rc, -1, 'timeout');
like($out, qr/timed out/, 'timeout diagnostic');
($rc, $out) = command(2, 64, $^X, '-e', 'print "x" x 1000');
is($rc, -1, 'bounded output');
like($out, qr/output limit/, 'output limit diagnostic');
($rc, $out) = command(0.2, 1024, $^X, '-e', 'exit if fork; sleep 10');
is($rc, -1, 'timeout covers descendants holding pipe');

my $base = "ia_pd 0 2001:db8:100:: 56\nmape_br 2001:db8::1\n";
my $wide = "mape_rule 0 16 192.0.2.0 24 2001:db8:: 32\nmape_portparams 6 8 42\n";
my $narrow = "mape_rule 0 8 198.51.100.0 24 2001:db8:100:: 48\n";
my %lease = parse_lease($base . $wide . $narrow);
is($lease{MAP_IPV4_PREFIX}, '198.51.100.0', 'longest matching BMR');
is($lease{DHCP_PSID_LEN}, 0, 'no port parameters inherited');
is($lease{PSID_OFFSET}, 6, 'default MAP offset');
my %reverse = parse_lease($base . $narrow . $wide);
is_deeply(\%reverse, \%lease, 'BMR selection independent of order');
my %roundtrip = parse_lease(lease_text(\%lease));
delete $roundtrip{portparams_seen};
is_deeply(\%roundtrip, \%lease, 'snapshot round trip');
eval { parse_lease($base . $narrow . $narrow) };
like($@, qr/ambiguous/, 'ambiguous BMR rejected');
eval { parse_lease($base . "mape_portparams 6 8 1\n") };
like($@, qr/without rule/, 'orphan parameters rejected');
my %zero = parse_lease($base . $narrow . "mape_portparams 0 0 123\n");
ok(complete_lease(\%zero), 'zero offset and length are complete');
is($zero{DHCP_PSID}, 0, 'zero-length PSID field ignored');

my %cfg = parse_config("VALUE=\"hello # world\" # comment\nEMPTY=\nPATH='/some path'\n");
is($cfg{VALUE}, 'hello # world', 'quoted comment preserved');
is($cfg{EMPTY}, '', 'empty literal');
my %again = parse_config(config_text(\%cfg));
is_deeply(\%again, \%cfg, 'canonical config round trip');
%cfg = (VALUE => "apostrophe's # value");
%again = parse_config(config_text(\%cfg));
is_deeply(\%again, \%cfg, 'literal quotes round trip');
for my $bad ('X=$HOME', 'X="$(id)"', 'X=`id`', 'export X=1', 'X=1; id', 'X="unterminated') {
	eval { parse_config($bad) };
	ok($@, "reject unsupported syntax: $bad");
}

my $live = "pppoe0 [Bound]\nIA_PD 0: 2001:db8:100::/56\nlease-seconds: 60\nMAP-E\nBR: 2001:db8::1\nrule: flags 0 ea-len 8 192.0.2.0/24 2001:db8:100::/48\n";
my ($kind, $seconds, $current) = live_lease($live, 'pppoe0');
is($kind, 'active', 'live bound lease authorizes service');
is($seconds, 60, 'exact remaining lifetime');
for my $state ('Renewing', 'Rebinding') {
	(my $text = $live) =~ s/Bound/$state/;
	($kind) = live_lease($text, 'pppoe0');
	is($kind, 'active', "$state remains authorized");
}
for my $state ('Down', 'Init', 'Requesting', 'Rebooting', 'IPv6 only') {
	($kind) = live_lease("pppoe0 [$state]\n", 'pppoe0');
	is($kind, 'withdrawn', "$state withdraws service");
}
(my $expired = $live) =~ s/lease-seconds: 60/lease-seconds: 0/;
($kind) = live_lease($expired, 'pppoe0');
is($kind, 'withdrawn', 'zero lifetime withdraws service');
(my $oldctl = $live) =~ s/lease-seconds: 60/lease 7 days/;
eval { live_lease($oldctl, 'pppoe0') };
like($@, qr/exact DHCP lifetime/, 'rounded lifetime is not authorization');
eval { live_lease($live, 'other0') };
like($@, qr/missing DHCP state/, 'wrong interface rejected');

is(effective_mtu('auto', 'pppoe0: flags=UP mtu 1492'), 1452, 'auto MTU');
is(effective_mtu('1452', 'pppoe0: flags=UP mtu 1500'), 1452, 'explicit MTU');
eval { effective_mtu('auto', 'pppoe0: mtu 1280') };
like($@, qr/invalid GIF MTU/, 'do not round unsafe auto MTU upward');
my %plan = (GIF_IF => 'gif0', GIF_MTU => 1452, CE_IPV6 => '2001:db8::1',
    BR_IPV6 => '2001:db8::2', MAPE_IPV4 => '192.0.2.1', PSID_OFFSET => 6,
    PSID_LEN => 8, PSID => 42);
my $gif = "gif0: flags=8051<UP,POINTOPOINT> mtu 1452\n tunnel: inet6 2001:db8::1 --> 2001:db8::2 ttl 64\n inet 192.0.2.1 --> 0.0.0.1 netmask 0xffffffff\n";
my $wan = ' inet6 2001:0db8:0:0:0:0:0:1 prefixlen 128';
my $rules = "match out on gif0 inet from any to any nat-to (gif0) map-e-portset 6/8/42\nmatch out on gif0 inet proto tcp flags S/SA scrub (max-mss 1412)\n";
my $route = " interface: gif0\n gateway: 0.0.0.1\n";
ok(has_ipv6($wan, $plan{CE_IPV6}), 'equivalent IPv6 spellings match');
is(runtime_mismatch(\%plan, $gif, $wan, $rules, $route), undef, 'matching runtime');
for my $case (
    [0, '1452', '1400', qr/MTU/],
    [0, 'UP,', '', qr/not UP/],
    [0, '2001:db8::2', '2001:db8::3', qr/endpoints/],
    [0, '192.0.2.1', '192.0.2.2', qr/IPv4 address/],
    [1, '2001:0db8:0:0:0:0:0:1', '2001:db8::3', qr/alias/],
    [2, '6/8/42', '6/8/43', qr/NAT parameters/],
    [2, 'max-mss 1412', 'max-mss 1400', qr/MSS/],
    [3, 'gif0', 'em0', qr/default route/]) {
	my @actual = ($gif, $wan, $rules, $route);
	$actual[$case->[0]] =~ s/\Q$case->[1]\E/$case->[2]/;
	like(runtime_mismatch(\%plan, @actual), $case->[3], "detect runtime mismatch: $case->[1]");
}
done_testing;
