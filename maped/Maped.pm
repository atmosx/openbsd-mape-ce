# Shared, unprivileged support for maped and its helpers.
package Maped;
use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton);
use Exporter 'import';
use IO::Select;
use POSIX qw(WNOHANG setpgid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
our @EXPORT_OK = qw(command status_text parse_lease complete_lease lease_text parse_config config_text live_lease);

sub status_text {
	my ($rc) = @_;
	return 'execution failed' if $rc == -1;
	return 'signal ' . ($rc & 127) if $rc & 127;
	return 'exit ' . ($rc >> 8);
}

# Bound both the process lifetime and captured output. Killing the process
# group also stops shell-helper descendants that inherited the output pipe.
sub command {
	my ($timeout, $limit, @cmd) = @_;
	pipe(my $reader, my $writer) or return (-1, "pipe: $!");
	my $pid = fork();
	if (!defined $pid) {
		close $reader; close $writer;
		return (-1, "fork: $!");
	}
	if (!$pid) {
		close $reader;
		setpgid(0, 0) == 0 or POSIX::_exit(127);
		open STDOUT, '>&', $writer or POSIX::_exit(127);
		open STDERR, '>&', $writer or POSIX::_exit(127);
		close $writer;
		exec { $cmd[0] } @cmd or do {
			print STDERR "cannot exec $cmd[0]: $!\n";
			POSIX::_exit(127);
		};
	}
	close $writer;
	setpgid($pid, $pid); # The child also establishes its group before exec.
	my $sel = IO::Select->new($reader);
	my $deadline = clock_gettime(CLOCK_MONOTONIC) + $timeout;
	my ($output, $error, $status) = ('', '', undef);
	while ($sel->count || !defined $status) {
		my $left = $deadline - clock_gettime(CLOCK_MONOTONIC);
		if ($left <= 0) { $error = 'command timed out'; last; }
		for my $fh ($sel->can_read($left < 0.1 ? $left : 0.1)) {
			my $n = sysread($fh, my $buf, 8192);
			if (!defined $n) {
				next if $!{EINTR};
				$error = "read: $!"; last;
			}
			if (!$n) { $sel->remove($fh); next; }
			if (length($output) + $n > $limit) {
				$error = 'command output limit exceeded'; last;
			}
			$output .= $buf;
		}
		last if $error;
		if (!defined $status && waitpid($pid, WNOHANG) == $pid) {
			$status = $?;
		}
		sleep 0.01 if !$sel->count && !defined $status;
	}
	if ($error) {
		kill 'TERM', -$pid;
		sleep 0.1;
		kill 'KILL', -$pid;
		waitpid($pid, 0) unless defined $status;
		close $reader;
		return (-1, "$error\n$output");
	}
	close $reader;
	return ($status == (127 << 8) ? -1 : $status, $output);
}

# Keep port parameters attached to their enclosing rule. Select one BMR by
# longest IPv6-prefix match (RFC 7597 section 5, RFC 7598 section 4.1).
sub parse_lease {
	my ($text) = @_;
	my (@pds, @rules, $rule, $br);
	for my $line (split /\n/, $text) {
		$line =~ s/^\s+|\s+$//g;
		if ($line =~ /^ia_pd\s+\d+\s+([\da-fA-F:]+)\s+(\d+)$/ ||
		    $line =~ /^IA_PD\s+\d+:\s+([\da-fA-F:]+)\/(\d+)$/) {
			die "invalid delegated prefix\n" unless inet_pton(AF_INET6, $1) && $2 <= 128;
			push @pds, [$1, $2];
		} elsif ($line =~ /^(?:mape_br|BR:)\s+([\da-fA-F:]+)$/i) {
			die "invalid BR\n" unless inet_pton(AF_INET6, $1);
			$br //= $1;
		} elsif ($line =~ /^mape_rule\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+([\da-fA-F:]+)\s+(\d+)$/i ||
		    $line =~ /^rule:\s+flags\s+(\d+)\s+ea-len\s+(\d+)\s+([\d.]+)\/(\d+)\s+([\da-fA-F:]+)\/(\d+)$/i) {
			$rule = {};
			@$rule{qw(MAP_RULE_FLAGS EA_LEN MAP_IPV4_PREFIX MAP_IPV4_PLEN MAP_IPV6_PREFIX MAP_IPV6_PLEN)} = ($1,$2,$3,$4,$5,$6);
			die "invalid MAP rule\n" unless $4 <= 32 && $6 <= 128 && $2 <= 48 &&
			    $6 + $2 <= 128 && inet_pton(AF_INET, $3) && inet_pton(AF_INET6, $5);
			@$rule{qw(PSID_OFFSET DHCP_PSID_LEN DHCP_PSID)} = (6, 0, 0);
			push @rules, $rule;
		} elsif ($line =~ /^mape_portparams\s+(\d+)\s+(\d+)\s+(\d+)$/i ||
		    $line =~ /^portparams:\s+offset\s+(\d+)\s+psid-len\s+(\d+)\s+psid\s+(\d+)$/i) {
			die "port parameters without rule\n" unless $rule;
			die "duplicate port parameters\n" if $rule->{portparams_seen}++;
			die "invalid port parameters\n" unless $1 <= 15 && $2 <= 16 && $1 + $2 <= 16 &&
			    (!$2 || $3 < 2 ** $2);
			@$rule{qw(PSID_OFFSET DHCP_PSID_LEN DHCP_PSID)} = ($1,$2,$2 ? $3 : 0);
		} elsif ($line =~ /^(?:ia_pd|IA_PD|mape_|BR:|rule:|portparams:)/) {
			die "malformed provisioning line: $line\n";
		}
	}
	return () unless @pds && @rules && defined $br;
	my @selected;
	for my $pd (@pds) {
		my $bits = unpack('B*', inet_pton(AF_INET6, $pd->[0]));
		my @match = sort { $b->{MAP_IPV6_PLEN} <=> $a->{MAP_IPV6_PLEN} }
		    grep { $_->{MAP_IPV6_PLEN} <= $pd->[1] &&
		    substr($bits, 0, $_->{MAP_IPV6_PLEN}) eq substr(unpack('B*',
		    inet_pton(AF_INET6, $_->{MAP_IPV6_PREFIX})), 0, $_->{MAP_IPV6_PLEN}) } @rules;
		next unless @match;
		die "ambiguous BMR\n" if @match > 1 && $match[0]{MAP_IPV6_PLEN} == $match[1]{MAP_IPV6_PLEN};
		push @selected, {%{$match[0]}, PD_PREFIX => join('/', @$pd), BR_IPV6 => $br};
	}
	die "multiple MAP delegated prefixes are not supported\n" if @selected > 1;
	return @selected ? %{$selected[0]} : ();
}

sub complete_lease {
	my ($l) = @_;
	for my $key (qw(PD_PREFIX BR_IPV6 EA_LEN MAP_IPV4_PREFIX MAP_IPV4_PLEN MAP_IPV6_PREFIX MAP_IPV6_PLEN PSID_OFFSET DHCP_PSID_LEN DHCP_PSID)) {
		return 0 unless defined $l->{$key} && $l->{$key} ne '';
	}
	return 1;
}

sub lease_text {
	my ($l) = @_;
	my ($addr, $plen) = split '/', $l->{PD_PREFIX};
	return "ia_pd 0 $addr $plen\nmape_br $l->{BR_IPV6}\nmape_rule " .
	    join(' ', map { $l->{$_} // 0 } qw(MAP_RULE_FLAGS EA_LEN MAP_IPV4_PREFIX MAP_IPV4_PLEN MAP_IPV6_PREFIX MAP_IPV6_PLEN)) .
	    "\nmape_portparams " . join(' ', @$l{qw(PSID_OFFSET DHCP_PSID_LEN DHCP_PSID)}) . "\n";
}

# A deliberately small shell-compatible language: literal assignments only.
# Do not execute configuration to discover values in a privileged daemon.
sub parse_config {
	my ($text) = @_;
	my %config;
	for my $line (split /\n/, $text) {
		next if $line =~ /^\s*(?:#.*)?$/;
		die "invalid configuration assignment: $line\n" unless
		    $line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
		my ($key, $rest) = ($1, $2);
		my $value = '';
		while (length $rest && $rest !~ /^\s/) {
			if ($rest =~ s/^'([^']*)'// || $rest =~ s/^"([^"\\\$`]*)"// ||
			    $rest =~ s/^([A-Za-z0-9_.\/:,{}@%+=-]+)//) {
				$value .= $1;
			} else {
				die "unsupported quoting or expansion for $key\n";
			}
		}
		die "trailing configuration text for $key\n" unless $rest =~ /^\s*(?:#.*)?$/;
		die "control character in $key\n" if $value =~ /[\x00-\x1f\x7f]/;
		$config{$key} = $value;
	}
	return %config;
}

sub config_text {
	my ($config) = @_;
	return join '', map {
		my $value = $config->{$_};
		$value =~ s/'/'"'"'/g;
		"$_='$value'\n";
	} sort keys %$config;
}

# Only current control output authorizes service. Rounded human-readable
# lifetimes and persisted restart hints cannot establish an expiry deadline.
sub live_lease {
	my ($text, $iface) = @_;
	my ($state) = $text =~ /^\Q$iface\E \[([^\]]+)\]$/m;
	die "missing DHCP state for $iface\n" unless defined $state;
	return ('withdrawn', 0, {}) if $state =~ /^(?:Down|Init|Requesting|Rebooting|IPv6 only)$/;
	die "unknown DHCP state: $state\n" unless $state =~ /^(?:Bound|Renewing|Rebinding)$/;
	return ('withdrawn', 0, {}) unless $text =~ /^\s*IA_PD /m && $text =~ /^\s*MAP-E\s*$/m;
	my ($seconds) = $text =~ /^\s*lease-seconds: (\d+)\s*$/m;
	die "missing exact DHCP lifetime; install dhcp6leasectl with -m support\n"
	    unless defined $seconds && $seconds <= 4294967295;
	return ('withdrawn', 0, {}) if $seconds == 0;
	my %lease = parse_lease($text);
	die "incomplete live MAP-E provisioning\n" unless complete_lease(\%lease);
	return ('active', $seconds, \%lease);
}
1;
