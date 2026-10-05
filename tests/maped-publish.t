use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../maped";
use MapedPublish;
sub service { +{name => $_[0], protocol => $_[1] || 'tcp', target_address => '127.0.0.1', target_port => 80} }
sub parse { MapedPublish::services(MapedPublish::encode({services => $_[0]})) }
my $p = {PSID_OFFSET => 6, PSID_LEN => 8, PSID => 42, MAPE_IPV4 => '192.0.2.66', GIF_IF => 'gif0'};
my $s = parse([service('z'), service('a'), service('dns', 'udp')]);
my $e = MapedPublish::assign($s, $p, []);
is_deeply([map { $_->{external_port} } @$e], [1192,1192,1193], 'lowest ports, sorted names, independent protocols');
my $more = parse([service('new'), @$s]);
my $retained = MapedPublish::assign($more, $p, $e);
is_deeply([map { $_->{external_port} } @$retained], [1192,1192,1194,1193], 'reserve preferences before new names');
my $changed = MapedPublish::assign($s, {%$p, PSID => 43}, $e);
is($changed->[0]{external_port}, 1196, 'stale ports cannot authorize new allocation');
my $full = MapedPublish::assign($s, {%$p, PSID_LEN => 0, PSID => 0}, []);
is($full->[0]{external_port}, 1024, 'unshared address starts at 1024');
eval { MapedPublish::assign(parse([service('a'),service('b')]), {%$p, PSID_OFFSET => 0, PSID_LEN => 16, PSID => 3032}, []) };
like($@, qr/insufficient/, 'exhaustion rejects whole candidate');
for my $bad ([service('a'), service('a')], [{%{service('a')}, protocol => 'icmp'}],
    [{%{service('a')}, target_address => '192.168.1.1'}], [{%{service('a')}, target_port => 0}],
    [{%{service('a')}, source_table => 'friends> from any'}], [{%{service('a')}, surprise => 1}],
    [{%{service('a')}, source_table => undef}], [{%{service('a')}, name => "a\n"}]) {
	eval { parse($bad) }; ok($@, 'reject malformed service');
}
eval { MapedPublish::services('{') }; ok($@, 'reject malformed JSON');
eval { MapedPublish::load('/nonexistent/maped-publish.json') }; ok($@, 'configured unreadable file fails closed');
is_deeply(MapedPublish::load(undef), [], 'disabled by default');
$p->{MAPED_PUBLISH_JSON} = MapedPublish::encode($e);
like(MapedPublish::rules($p), qr/pass in quick on gif0 inet proto tcp from any to 192\.0\.2\.66 port 1192 rdr-to 127\.0\.0\.1 port 80/, 'render router-local redirect');
$e->[0]{source_table} = 'trusted';
$p->{MAPED_PUBLISH_JSON} = MapedPublish::encode($e);
like(MapedPublish::rules($p), qr/from <trusted>/, 'source table remains restricted');
$e->[0]{external_port} = 80;
$p->{MAPED_PUBLISH_JSON} = MapedPublish::encode($e);
eval { MapedPublish::rules($p) }; like($@, qr/invalid published assignment/, 'renderer rechecks authorization');
done_testing;
