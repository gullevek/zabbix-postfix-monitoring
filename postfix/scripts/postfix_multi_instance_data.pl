#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/2/22
# UPDATE: 2019/2/22
# DESC  : read data from the temp file and return json string for
#         the multi instance postfix syslog name given on command line

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
my $state_folder = '/var/local/zabbix/';
my $json_tmp_file = $state_folder.'zabbix-postfix.tmp.json';
my $syslog_name;
my $values;
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

# check that the tmp.json file exists
if (-f $json_tmp_file) {
	open(FH, '<', $json_tmp_file) || die ("Can't open json temp file: $json_tmp_file: ".$!."\n");
	$values = decode_json(<FH>);
	close(FH);
	# check if we have any data for the selected syslog name
	if ($values->{$syslog_name}) {
		# if debug print out formated list
		if ($debug) {
			foreach my $_key (sort keys %{$values->{$syslog_name}}) {
				print "[$syslog_name] $_key: ".$values->{$syslog_name}->{$_key}."\n";
			}
		} else {
			# print out the json data only for selected syslog name
			print encode_json($values->{$syslog_name});
		}
	} else {
		print '{"error":"syslog name not found: '.$syslog_name.'"}';
	}
} else {
	# empty return
	print '{"error":"json tmp file not found"}';
}

# __END__
