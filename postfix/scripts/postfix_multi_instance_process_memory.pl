#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/2/28
# UPDATE: 2019/2/28
# DESC  : get the running processes per multi instance

use strict;
use warnings;

BEGIN {
	use Getopt::Long;
	use JSON qw(encode_json);
}

# getopt
my $result;
my %opt;
# storage variables
my $syslog_name;
my $queue_dir;
my $pid;
my $processes;
my @process_list = ();
# define list of data that needs to be there and is init as 0 if not set
my @default_process_list = ('anvil', 'bounce', 'cleanup', 'flush', 'local', 'pickup', 'qmgr', 'scache', 'showq', 'smtpd', 'smtp', 'tlsmgr', 'trivial-rewrite', 'verify', 'virtual');
# general variables
my $debug = 0;

# command line options
$result = GetOptions(\%opt,
	'syslog-name|s=s' => \$syslog_name,
	'debug' => \$debug,
	'h|help|?' # just help
) || exit 1;

if ($opt{'help'}) {
	print "HELP MESSAGE:\n";
	print "--syslog-name|-s: name of the syslog group that should be read from the json file\n";
	print "--debug: debug output (not json encoded default output)\n";
	exit 1;
}

if (!$syslog_name) {
	print "Syslog name needs to be provided\n";
	exit 1;
}

# needs to get the master.pid for the given syslog name
# so we need to get the spool folder
$queue_dir = `/usr/sbin/postmulti -i $syslog_name -x postconf -xh queue_directory 2>/dev/null`;
chomp $queue_dir;
# if we don't have a queue dir, check if this syslog name matches the master name, if not error on not found
if (!$queue_dir) {
	my $_syslog_name = `/usr/sbin/postmulti -i - -x postconf -xh syslog_name`;
	chomp $_syslog_name;
	if ($_syslog_name && $_syslog_name eq $syslog_name) {
		$queue_dir = `/usr/sbin/postmulti -i - -x postconf -xh queue_directory 2>/dev/null`;
		chomp $queue_dir;
	}
}
# if we have a queue dir
if ($queue_dir) {
	# get the master pid & remove all spaced
	# NOTE needs sudo entry for cat -> pid/master.pid
	$pid = `sudo cat $queue_dir/pid/master.pid 2>/dev/null`;
	chomp $pid;
	$pid =~ s/\s+//;
	# needs pgrep installed
	@process_list = split(/,/, `/usr/bin/pgrep -l -d , -P $pid`);
	foreach my $_process_list (@process_list) {
		# split up to pid and process name
		my ($_pid, $_process) = split(/\s+/, $_process_list);
		chomp($_process);
		$processes->{$_process}->{'num'} ++;
	}
	# get memory (in KB)
	# ps -o pid:1=,comm=,vsz:1= --ppid 13596
	open(FH, 'ps -o pid:1=,comm=,vsz:1= --ppid '.$pid.'|') || die("Can't open ps: ".$!."\n");
	while (<FH>) {
		chomp;
		my ($_pid, $_process, $_mem) = split(/\s+/, $_);
		$processes->{$_process}->{'mem'} += $_mem;
	}
	close(FH);
	# loop through default and fill missing with 0
	foreach my $_process (@default_process_list) {
		if (!$processes->{$_process}->{'num'}) {
			$processes->{$_process}->{'num'} = 0;
			$processes->{$_process}->{'mem'} = 0;
		}
	}
	# ouput debug print or json encode
	if ($debug) {
		foreach my $_key (sort keys %$processes) {
			foreach my $_sub ('num', 'mem') {
				print "[$syslog_name] ".$_key."[".$_sub."]: ".$processes->{$_key}->{$_sub}."\n";
			}
		}
	} else {
		print encode_json($processes);
	}
} else {
	# no queue dir, no syslog name, just skip with empty
	print '{"error":"queue directory not found: '.$syslog_name.'"}';
}

# __END__
