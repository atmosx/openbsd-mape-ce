# Read-only reporting; never use this data to authorize MAP-E service.
package MapedStatus;
use strict;
use warnings;
use JSON::PP ();
use POSIX qw(strftime);
use File::Temp qw(tempfile);

sub new {
	my ($class, $path) = @_;
	my $self = bless {path => $path, record => [], publish_events => [], published => []}, $class;
	if (-e $path) {
		open my $fh, '<', $path or die "status open: $!";
		local $/;
		my $old = JSON::PP::decode_json(<$fh>);
		close $fh or die "status close: $!";
		die "unsupported or invalid status history\n" unless
		    ref($old) eq 'HASH' && ($old->{schema_version} // 0) == 1 &&
		    ref($old->{record}) eq 'ARRAY';
		for my $r (@{$old->{record}}) {
			die "invalid status record\n" unless ref($r) eq 'HASH' &&
			    ref($r->{allocation}) eq 'HASH' && defined $r->{'first-seen'} &&
			    defined $r->{'last-seen'};
		}
		$self->{record} = $old->{record};
		$self->{publish_events} = $old->{publish_events} || [];
		die "invalid publishing history\n" unless ref($self->{publish_events}) eq 'ARRAY';
		for my $event (@{$self->{publish_events}}) {
			die "invalid publishing event\n" unless ref($event) eq 'HASH' && ref($event->{endpoints}) eq 'ARRAY';
		}
		$self->{published} = $self->{publish_events}[-1]{endpoints} if @{$self->{publish_events}};
	}
	return $self;
}

# Preferences survive withdrawal, but the allocator must recheck authorization.
sub publish_preferences {
	my ($self) = @_;
	for my $event (reverse @{$self->{publish_events}}) {
		return $event->{endpoints} if @{$event->{endpoints}};
	}
	return [];
}

sub stamp { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])); }

sub port_set {
	my ($a, $k, $psid) = @_;
	for ($a, $k, $psid) {
		die "invalid port-set integer\n" unless defined && /^\d+$/;
	}
	die "invalid port set\n" if $a > 15 || $k > 16 - $a ||
	    $psid >= (1 << $k);
	my @ranges;
	if ($k == 0) {
		# No address sharing: MAP imposes no port-set restriction.
		@ranges = ({first => 0, last => 65535});
	} else {
		my $m = 16 - $a - $k;
		for my $i (($a ? 1 : 0) .. (1 << $a) - 1) {
			my $first = ($i << (16 - $a)) | ($psid << $m);
			push @ranges, {first => $first, last => $first + (1 << $m) - 1};
		}
	}
	my $count = 0;
	$count += $_->{last} - $_->{first} + 1 for @ranges;
	return {restricted => $k ? JSON::PP::true : JSON::PP::false,
	    offset => 0 + $a, psid_length => 0 + $k, psid => 0 + $psid,
	    port_count => $count, block_count => scalar @ranges,
	    protocols => ['tcp', 'udp'], ranges => \@ranges};
}

sub allocation {
	my ($p) = @_;
	return {ipv4_address => $p->{MAPE_IPV4}, ce_ipv6_address => $p->{CE_IPV6},
	    br_ipv6_address => $p->{BR_IPV6}, delegated_ipv6_prefix => $p->{PD_PREFIX},
	    offset => 0 + $p->{PSID_OFFSET}, psid_length => 0 + $p->{PSID_LEN},
	    psid => 0 + $p->{PSID}};
}

sub publish {
	my ($self, %args) = @_;
	my $now = $args{now} // time;
	my $json = JSON::PP->new->canonical->pretty;
	my $doc = {schema_version => 1, status => $args{status},
	    'last-update' => stamp($now), updated_at_epoch => 0 + $now,
	    lease_interface => $args{lease_interface}, tunnel_interface => $args{tunnel_interface},
	    reason => $args{reason}, allocation => undef, port_set => undef,
	    lease_expires_at => defined $args{expires} ? stamp($args{expires}) : undef,
	    last_confirmed_at => defined $args{confirmed} ? stamp($args{confirmed}) : undef};
	# Copy before mutation: failed publication must not advance in-memory history.
	my $records = JSON::PP::decode_json($json->encode($self->{record}));
	if (my $p = $args{plan}) {
		my $allocation = allocation($p);
		$doc->{allocation} = $allocation;
		$doc->{port_set} = port_set(@$p{qw(PSID_OFFSET PSID_LEN PSID)});
		if ($args{status} eq 'active') {
			if (@$records && $json->encode($records->[-1]{allocation}) eq $json->encode($allocation)) {
				$records->[-1]{'last-seen'} = stamp($now);
			} else {
				push @$records, {allocation => $allocation,
				    'first-seen' => stamp($now), 'last-seen' => stamp($now)};
			}
		}
	}
	$doc->{record} = $records;
	my $endpoints = $args{plan} ? JSON::PP::decode_json($args{plan}{MAPED_PUBLISH_JSON} || '[]') : [];
	$doc->{published_endpoints} = $endpoints;
	my @events = @{$self->{publish_events}};
	my $published = $self->{published};
	if ($args{status} !~ /^(?:initializing|applying)$/ &&
	    $json->encode($published) ne $json->encode($endpoints)) {
		push @events, {at => stamp($now), status => $args{status}, endpoints => $endpoints};
		$published = $endpoints;
	}
	$doc->{publish_events} = \@events;
	(my $dir = $self->{path}) =~ s{/[^/]+$}{};
	my ($fh, $tmp) = tempfile('status.XXXXXXXX', DIR => $dir);
	my $ok = eval {
		print {$fh} $json->encode($doc) or die "status write: $!";
		close $fh or die "status close: $!";
		rename $tmp, $self->{path} or die "status rename: $!";
		1;
	};
	if (!$ok) { my $err = $@; close $fh; unlink $tmp; die $err; }
	$self->{record} = $records;
	$self->{publish_events} = \@events;
	$self->{published} = $published;
	return $doc;
}
1;
