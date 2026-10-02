# Exercise a temporary copy of the real daemon with mocked privileged tools.
# Only the UID admission checks are adjusted; production has no test bypass.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep time);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../maped";
use Maped qw(command config_text);
my $repo = "$FindBin::Bin/..";
my $tmp = tempdir(CLEANUP => 1);
sub readfile {
	open my $fh, '<', $_[0] or die "$_[0]: $!";
	local $/; return <$fh> // '';
}
sub writefile {
	open my $fh, '>', $_[0] or die "$_[0]: $!";
	print {$fh} $_[1]; close $fh or die $!;
}
my $code = readfile("$repo/maped/maped");
my $n = ($code =~ s/if \(\$> != 0\) \{.*?^\}//ms);
is($n, 1, 'remove only root admission in temporary test copy');
$n = ($code =~ s/\$state_stat\[4\] != 0/\$state_stat[4] != \$>/);
is($n, 1, 'test state directory owned by test UID');
writefile("$tmp/maped", $code);
copy("$repo/maped/Maped.pm", "$tmp/Maped.pm") or die $!;
mkdir "$tmp/state";
my $live = readfile("$repo/tests/fixtures/dhcp6leasectl.txt");
$live =~ s/lease 7 days/lease-seconds: 60/;
writefile("$tmp/live", $live);
for my $name (qw(ctl up down ifconfig pfctl route)) {
	my $body = {
	    ctl => "[ ! -f '$tmp/fail' ] || exit 1\ncat '$tmp/live'\n",
	    up => "echo up >> '$tmp/calls'\ntest -s \"\$2\"\n. \"\$1\"\necho \"\$GIF_MTU\" > '$tmp/gif_mtu'\ntouch '$tmp/installed'\n",
	    down => "echo down >> '$tmp/calls'\nrm -f '$tmp/installed'\n",
	    ifconfig => "case \"\$1\" in\npppoe0) echo \"pppoe0: flags=UP mtu \$(cat '$tmp/wan_mtu')\"; [ ! -f '$tmp/installed' ] || echo ' inet6 2001:db8:100:4200:0:c000:242:2a prefixlen 128';;\n*) echo \"gif0: flags=<UP> mtu \$(cat '$tmp/gif_mtu')\"; echo ' tunnel: inet6 2001:db8:100:4200:0:c000:242:2a --> 2001:db8:ffff::1 ttl 64'; echo ' inet 192.0.2.66 --> 0.0.0.1 netmask 0xffffffff';;\nesac\n",
	    pfctl => "echo 'match out on gif0 inet from any to any nat-to (gif0) map-e-portset 6/8/42'\necho \"match out on gif0 inet proto tcp flags S/SA scrub (max-mss \$((\$(cat '$tmp/gif_mtu') - 40)))\"\n",
	    route => "echo ' interface: gif0'\necho ' gateway: 0.0.0.1'\n",
	}->{$name};
	writefile("$tmp/$name", "#!/bin/sh\n$body"); chmod 0755, "$tmp/$name";
}
writefile("$tmp/calls", '');
writefile("$tmp/wan_mtu", "1492\n");
writefile("$tmp/gif_mtu", "1452\n");
my %conf = (WAN_IF => 'pppoe0', LEASE_IF => 'pppoe0', GIF_IF => 'gif0',
    GIF_MTU => 'auto', LAN_NET => '192.168.1.0/24', MAPED_STATE_DIR => "$tmp/state",
    MAPED_UP => "$tmp/up", MAPED_DOWN => "$tmp/down", MAPED_DERIVE => "$repo/maped/maped-derive",
    DHCP6LEASECTL => "$tmp/ctl", IFCONFIG => "$tmp/ifconfig", PFCTL => "$tmp/pfctl", ROUTE => "$tmp/route");
writefile("$tmp/conf", config_text(\%conf));
sub once {
	return command(10, 65536, $^X, "$tmp/maped", '-1', '-f', '-p', "$tmp/conf");
}
my ($rc, $out) = once();
is($rc, 0, 'one-shot configures current live lease') or diag $out;
is(readfile("$tmp/calls"), "up\n", 'helper called once');
ok(-f "$tmp/state/applied.conf", 'ownership recorded');
($rc, $out) = once();
is($rc, 0, 'unchanged healthy state succeeds') or diag $out;
is(readfile("$tmp/calls"), "up\n", 'unchanged state not recreated');
writefile("$tmp/wan_mtu", "1500\n");
($rc, $out) = once();
is($rc, 0, 'WAN MTU change repaired') or diag $out;
is(readfile("$tmp/gif_mtu"), "1460\n", 'auto MTU recomputed');
writefile("$tmp/wan_mtu", "1492\n");
($rc, $out) = once();
is($rc, 0, 'WAN MTU restored') or diag $out;
writefile("$tmp/calls", "up\n");
writefile("$tmp/live", "pppoe0 [Init]\n");
($rc, $out) = once();
is($rc, 0, 'confirmed withdrawal succeeds') or diag $out;
is(readfile("$tmp/calls"), "up\ndown\n", 'withdrawal invokes down helper');
ok(!-f "$tmp/state/applied.conf", 'ownership removed after cleanup');
writefile("$tmp/live", $live);
($rc, $out) = once();
is($rc, 0, 'new live lease reapplied') or diag $out;
writefile("$tmp/fail", '');
($rc, $out) = once();
ok($rc != 0, 'failed read returns failure');
is(readfile("$tmp/calls"), "up\ndown\nup\ndown\n", 'restart without proof retires owned state');
unlink "$tmp/fail";
writefile("$tmp/up", "#!/bin/sh\nexit 3\n");
($rc, $out) = once();
ok($rc != 0, 'failed apply returns failure');
ok(!-f "$tmp/state/applied.conf", 'partial apply retired');

writefile("$tmp/up", "#!/bin/sh\necho up >> '$tmp/calls'\n");
writefile("$tmp/calls", '');
(my $short = $live) =~ s/lease-seconds: 60/lease-seconds: 4/;
writefile("$tmp/live", $short);
my $pid = fork();
die $! unless defined $pid;
if (!$pid) {
	open STDOUT, '>', "$tmp/daemon.log" or die $!;
	open STDERR, '>&', STDOUT or die $!;
	exec $^X, "$tmp/maped", '-f', '-p', '-i', '1', "$tmp/conf";
	die $!;
}
my $end = time() + 3;
sleep 0.05 while readfile("$tmp/calls") eq '' && time() < $end;
is(readfile("$tmp/calls"), "up\n", 'continuous daemon configured');
writefile("$tmp/fail", '');
sleep 1.2;
is(readfile("$tmp/calls"), "up\n", 'read failure retains still-valid service');
sleep 3.5;
like(readfile("$tmp/calls"), qr/up\ndown\n/, 'read failure cannot extend confirmed expiry');
kill 'TERM', $pid;
waitpid($pid, 0);

SKIP: {
	skip 'OpenBSD-only sandbox failure test', 2 unless $^O eq 'openbsd';
	mkdir "$tmp/deny" or die $!;
	mkdir "$tmp/deny/OpenBSD" or die $!;
	writefile("$tmp/deny/OpenBSD/Pledge.pm", "die qq(intentional module failure\\n);\n");
	local $ENV{PERL5LIB} = "$tmp/deny";
	($rc, $out) = once();
	isnt($rc, 0, 'missing pledge module stops OpenBSD daemon');
	like($out, qr/pledge\/unveil unavailable on OpenBSD/, 'sandbox failure is explicit');
}
done_testing;
