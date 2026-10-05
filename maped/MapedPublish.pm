# Optional inbound publishing. Saved endpoints are preferences, not authority.
package MapedPublish;
use strict;
use warnings;
use JSON::PP ();
use MapedStatus;

sub services {
	my ($text) = @_;
	my $doc = JSON::PP::decode_json($text);
	die "publish file must contain only a services array\n" unless
	    ref($doc) eq 'HASH' && keys(%$doc) == 1 && ref($doc->{services}) eq 'ARRAY';
	my %names;
	for my $s (@{$doc->{services}}) {
		die "invalid publish service\n" unless ref($s) eq 'HASH';
		my %allowed = map { $_ => 1 } qw(name protocol target_address target_port source_table);
		die "unknown publish field\n" if grep { !$allowed{$_} } keys %$s;
		for (qw(name protocol target_address target_port)) {
			die "missing or invalid publish $_\n" unless defined $s->{$_} && !ref($s->{$_});
		}
		die "invalid or duplicate service name\n" unless $s->{name} =~ /\A[A-Za-z][A-Za-z0-9_-]{0,47}\z/ && !$names{$s->{name}}++;
		die "invalid publish protocol\n" unless $s->{protocol} =~ /\A(?:tcp|udp)\z/;
		die "only router-local 127.0.0.1 targets are supported\n" unless $s->{target_address} eq '127.0.0.1';
		die "invalid target port\n" unless $s->{target_port} =~ /\A[1-9][0-9]{0,4}\z/ && $s->{target_port} <= 65535;
		if (exists $s->{source_table}) {
			die "invalid source table\n" unless defined $s->{source_table} && !ref($s->{source_table}) &&
			    $s->{source_table} =~ /\A[A-Za-z_][A-Za-z0-9_]{0,30}\z/;
		}
		$s->{target_port} = 0 + $s->{target_port};
	}
	return [sort { $a->{name} cmp $b->{name} } @{$doc->{services}}];
}

sub load {
	my ($path) = @_;
	return [] unless defined $path && length $path;
	open my $fh, '<', $path or die "cannot read publish file $path: $!\n";
	local $/;
	return services(<$fh>);
}

sub assign {
	my ($services, $plan, $previous) = @_;
	my $set = MapedStatus::port_set(@$plan{qw(PSID_OFFSET PSID_LEN PSID)});
	my %permitted;
	for my $r (@{$set->{ranges}}) {
		$permitted{$_} = 1 for grep { $_ >= 1024 } $r->{first} .. $r->{last};
	}
	my (%used, %assigned);
	my %old = map { ref($_) eq 'HASH' ? ($_->{name} // '' => $_) : () } @{$previous || []};
	# Reserve all still-valid preferences before allocating new services.
	for my $s (@$services) {
		my $o = $old{$s->{name}} or next;
		my $p = $o->{external_port};
		next unless defined $p && !ref($p) && $permitted{$p} &&
		    ($o->{protocol} // '') eq $s->{protocol} && !$used{$s->{protocol}}{$p};
		$assigned{$s->{name}} = 0 + $p;
		$used{$s->{protocol}}{$p} = 1;
	}
	my @ports = sort { $a <=> $b } keys %permitted;
	my @endpoints;
	for my $s (@$services) {
		my $p = $assigned{$s->{name}};
		if (!defined $p) {
			($p) = grep { !$used{$s->{protocol}}{$_} } @ports;
			die "insufficient MAP-E ports for publishing\n" unless defined $p;
			$used{$s->{protocol}}{$p} = 1;
		}
		push @endpoints, {%$s, external_address => $plan->{MAPE_IPV4}, external_port => 0 + $p};
	}
	return \@endpoints;
}

sub encode { JSON::PP->new->canonical->encode($_[0]) }

sub rules {
	my ($plan) = @_;
	my $endpoints = JSON::PP::decode_json($plan->{MAPED_PUBLISH_JSON} || '[]');
	return '' unless @$endpoints;
	die "invalid publishing interface\n" unless $plan->{GIF_IF} =~ /\A[a-z][a-z0-9]*\z/;
	# Revalidate stored candidate fields and authorization before rendering PF.
	my @services = map { my %s = %$_; delete @s{qw(external_address external_port)}; \%s } @$endpoints;
	my $services = services(encode({services => \@services}));
	my $checked = assign($services, $plan, $endpoints);
	die "invalid published assignment\n" unless encode($checked) eq encode($endpoints);
	die "invalid publishing IPv4 address\n" unless $plan->{MAPE_IPV4} =~ /\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z/;
	return join '', map {
		my $source = exists $_->{source_table} ? "<$_->{source_table}>" : 'any';
		"pass in quick on $plan->{GIF_IF} inet proto $_->{protocol} from $source to $_->{external_address} port $_->{external_port} rdr-to $_->{target_address} port $_->{target_port} label \"maped-publish-$_->{name}\"\n"
	} @$checked;
}
1;
