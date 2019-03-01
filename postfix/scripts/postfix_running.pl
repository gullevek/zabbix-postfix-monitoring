#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/2/25
# UPDATE: 2019/2/28
# DESC  : read running/not running status via postmulti for an instance

use strict;
use warnings;

BEGIN {
	use Getopt::Long;
	use JSON qw(decode_json encode_json);
}

# getopt
my $result;
my %opt;
# storage variables
my $syslog_name = '-';
my $queue_dir;
my $daemon_dir;
my $process_dir;
my $pid;
my $running = 3;
# general variables
my $debug = 0;

# command line options
$result = GetOptions(\%opt,
	'syslog-name|s=s' => \$syslog_name,
	'debug' => \$debug,
	'h|help|?' # just help
) || exit 1;

if ($syslog_name) {
	# we can't use the postfix -i ... -p status because it logs to syslog and not to stdout
	# we need to check the pid in the spool/pid dir and compare the daemon paths
	# -hx queue_directory 2>/dev/null || echo /var/spool/postfix
	$queue_dir = `/usr/sbin/postmulti -i $syslog_name -x postconf -xh queue_directory 2>/dev/null`;
	chomp $queue_dir;
	# if we have a queue dir
	if ($queue_dir) {
		# get base daemon dir
		$daemon_dir = `/usr/sbin/postmulti -i $syslog_name -x postconf -xh daemon_directory 2>/dev/null`;
		chomp $daemon_dir;
		# get the master pid & remove all spaced
		# NOTE needs sudo entry for cat -> pid/master.pid
		$pid = `sudo cat $queue_dir/pid/master.pid 2>/dev/null`;
		chomp $pid;
		$pid =~ s/\s+//;
		# if pid is a digit and exec file exists in /proc/ continue
		if ($pid =~ /\d+/ && -f '/proc/'.$pid.'/cmdline') {
			# get the original process path
			$process_dir = `cat /proc/$pid/cmdline`;
			# remove anything beyond the ^@ (null byte)
			# not needed -> everything beyond the last slash is removed in the regex below
			# $process_dir =~ s/\x0//g;
			# clean up (remove master from beyond the last slash, remove last slash)
			$process_dir =~ s/\/[^\/]*$//;
			# strip any trailing / in the daemon_dir
			$daemon_dir =~ s/\/$//;
			# in the pid dir check that process with this pid is running and matching
			if ($process_dir eq $daemon_dir) {
				$running = 1;
			} else {
				$running = 0;
			}
		} else {
			$running = 0;
		}
	} else {
		# no queue dir found at all (invalid syslog name)
		$running = 2;
	}
}

print $running;

# __END__
