#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/2/21
# UPDATE: 2019/2/21
# DESC  : discovery for multiple postfix instances

use strict;
use warnings;

BEGIN {
	use Getopt::Long;
	use JSON qw(encode_json);
}

# getop
my $result;
my %opt;
# postfix master config
my $postfix_config_default = '/etc/postfix/';
my $postfix_config_master = '';
# process variables
my @row = ();
my @syslog_names = ();
my $syslog_name;
my $postfix_config;
my $multi_instance_syslog_name;
my $jstring;
my $msg;

# command line options
$result = GetOptions(\%opt,
	'config|c=s' => \$postfix_config_master,
	'h|help|?' # just help
) || exit 1;

if ($opt{'help'}) {
	print "HELP MESSAGE:\n";
	print "-c|--config: override default location for postfix config (/etc/postfix)\n";
	exit 1;
}

# set postfix config if not set from options
if (!$postfix_config_master) {
	$postfix_config_master = $postfix_config_default;
}
# strip trailing /
$postfix_config_master =~ s/\/$//;
# check that config file is a valid directory
if (! -d $postfix_config_master) {
	print "Postfix config directory could not be found at: ".$postfix_config_master."\n";
	exit 0;
}

# check if multiple postfix is enabled on the default postfix
$msg = `/usr/sbin/postconf -c $postfix_config_master -h multi_instance_enable 2>/dev/null`;
chomp $msg;
if ($msg =~ /yes/i) {
	# run the postmulti command and collect all entries that are not - (non default)
	# if only - is found return nothing (empty list)
	open(FH, '/usr/sbin/postmulti -l|') || die ("Cannot open postmulti list\n");
	while (<FH>) {
		chomp;
		# layout is space separted list
		# split up between all spaces
		@row = split(/\s+/, $_);
		# 0: multi instance name
		# 1: group name (ignore)
		# 2: enabled (y/n)
		# 3: config folder
		# get the syslog_name/multi_instance_name based on the config folder for all the entries
		$postfix_config = $row[3];
		$syslog_name = `/usr/sbin/postconf -c $postfix_config -h syslog_name 2>/dev/null`;
		chomp $syslog_name;
		if ($syslog_name =~ /^\$\{/) {
			# if we have multi instance enabled and we have a multi_instance_name, use this, else fall back to syslog name
			$multi_instance_syslog_name = `/usr/sbin/postconf -c $postfix_config -h multi_instance_name 2>/dev/null`;
			chomp $multi_instance_syslog_name;
			if ($multi_instance_syslog_name) {
				$syslog_name = $multi_instance_syslog_name;
			} else {
				# syslogname can be dynamic set with ${, if this is the case split with : and get last part, strip out any {} left over
				# sample: ${multi_instance_name?{$multi_instance_name}:{postfix}}
				$syslog_name = (split(/:/, $syslog_name))[1];
				$syslog_name =~ s/[\{\}]//g;
			}
		}
		push(@syslog_names, {'#syslog_name' => $syslog_name});
	}
}
if (@syslog_names) {
	$jstring->{'data'} = [@syslog_names];
} else {
	$jstring->{'data'} = [];
}
print encode_json($jstring);

# __END__
