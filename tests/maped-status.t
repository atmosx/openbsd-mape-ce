use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../maped";
use MapedStatus;

my $set = MapedStatus::port_set(6, 6, 63);
is($set->{port_count}, 1008, 'Cosmote allocation size');
is($set->{block_count}, 63, '63 blocks');
is_deeply($set->{ranges}[0], {first => 2032, last => 2047}, 'first block');
is_deeply($set->{ranges}[-1], {first => 65520, last => 65535}, 'last block');
is(MapedStatus::port_set(6, 0, 0)->{restricted}, 0, 'no sharing is unrestricted');
is(MapedStatus::port_set(0, 16, 65535)->{port_count}, 1, 'zero offset boundary');
for my $bad ([16,1,0], [6,11,0], [6,6,64], [6,0,1], [-1,1,0], ['x',1,0]) {
	ok(!eval { MapedStatus::port_set(@$bad); 1 }, 'invalid tuple rejected');
}
for my $a (1..15) {
	for my $k (1..16-$a) {
		for my $p (0, (1 << $k)-1) {
			my $s = MapedStatus::port_set($a,$k,$p);
			my $m = 16-$a-$k;
			my $valid = $s->{port_count} == ((1 << $a)-1)*(1 << $m);
			my $last = -1;
			for my $r (@{$s->{ranges}}) {
				$valid &&= $r->{first} > $last && $r->{last} <= 65535 &&
				    (($r->{first} >> $m) & ((1 << $k)-1)) == $p;
				$last = $r->{last};
			}
			ok($valid, "range invariant $a/$k/$p");
		}
	}
}
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/status.json";
my $s = MapedStatus->new($path);
my %p = (MAPE_IPV4 => '87.202.58.210', CE_IPV6 => '2a02:586:6234:bf00:0:57ca:3ad2:3f',
    BR_IPV6 => '2a02:586::406', PD_PREFIX => '2a02:586:6234:bf00::/56',
    PSID_OFFSET => 6, PSID_LEN => 6, PSID => 63);
sub publish { $s->publish(status => 'active', plan => \%p, @_); }
my $d = publish(now => 1000);
is($d->{'last-update'}, '1970-01-01T00:16:40Z', 'UTC timestamp');
is(scalar @{$d->{record}}, 1, 'initial history');
$d = publish(now => 2000);
is(scalar @{$d->{record}}, 1, 'unchanged observation not duplicated');
is($d->{record}[0]{'first-seen'}, '1970-01-01T00:16:40Z', 'first observation retained');
is($d->{record}[0]{'last-seen'}, '1970-01-01T00:33:20Z', 'last observation refreshed');
$d = $s->publish(status => 'degraded', plan => \%p, now => 3000);
is($d->{record}[0]{'last-seen'}, '1970-01-01T00:33:20Z', 'failed query does not advance observation');
$p{PSID} = 62;
$d = publish(now => 4000);
is(scalar @{$d->{record}}, 2, 'PSID-only change recorded');
$p{MAPE_IPV4} = '87.202.58.211';
$p{PD_PREFIX} = '2a02:586:6234:c000::/56';
$d = publish(now => 5000);
is(scalar @{$d->{record}}, 3, 'address change recorded');
$d = $s->publish(status => 'inactive', now => 6000);
ok(!defined $d->{allocation} && !defined $d->{port_set}, 'inactive clears allocation');
is(scalar @{$d->{record}}, 3, 'inactive retains history');
$s = MapedStatus->new($path);
$d = $s->publish(status => 'initializing', now => 7000);
ok(!defined $d->{allocation}, 'restart cannot inherit active allocation');
is(scalar @{$d->{record}}, 3, 'history survives restart');
$p{MAPE_IPV4} = '87.202.58.210'; $p{PSID} = 63;
$p{PD_PREFIX} = '2a02:586:6234:bf00::/56';
$d = publish(now => 8000);
is(scalar @{$d->{record}}, 4, 'return to old allocation is another transition');
open my $fh, '<', $path or die $!;
my $saved = do { local $/; decode_json(<$fh>) }; close $fh;
is_deeply($saved, $d, 'complete JSON committed');
is((stat($path))[2] & 0777, 0600, 'private reporting history');
my @tmp = glob "$dir/status.*";
is(scalar @tmp, 1, 'no temporary files after successful publication');
# Force rename failure after tempfile creation. History must not advance.
my $broken = MapedStatus->new("$dir/blocked");
mkdir "$dir/blocked" or die $!;
ok(!eval { $broken->publish(status => 'active', plan => \%p, now => 9000); 1 }, 'write failure reported');
is_deeply($broken->{record}, [], 'failed write does not advance history');
@tmp = glob "$dir/status.*";
is(scalar @tmp, 1, 'failed publication cleans temporary file');
open $fh, '>', $path or die $!; print {$fh} '{broken'; close $fh;
ok(!eval { MapedStatus->new($path); 1 }, 'corrupt history not silently discarded');
done_testing;
