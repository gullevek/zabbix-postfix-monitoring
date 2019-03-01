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
	if (!$debug) {
		print encode_json($processes);
	} else {
		foreach my $_key (sort keys %$processes) {
			print "[$syslog_name] ".$_key."[num]: ".$processes->{$_key}->{'num'}."\n";
		}
	}
} else {
	# no queue dir, no syslog name, just skip with empty
	print '{"error":"queue directory not found: '.$queue_dir.'"}';
}

# __END__
