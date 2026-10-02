# Shared, unprivileged support for maped and its helpers.
package Maped;
use strict;
use warnings;
use Exporter 'import';
use IO::Select;
use POSIX qw(WNOHANG setpgid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
our @EXPORT_OK = qw(command status_text);

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
1;
