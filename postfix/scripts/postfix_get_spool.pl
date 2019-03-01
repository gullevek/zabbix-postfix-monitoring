#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/3/1
# UPDATE: 2019/3/1
# DESC  : sub process for the postfix.pl runner
#         * checks spool folder for the following counts
#           - maildrop
#           - incoming
#           - corrupt

use strict;
use warnings;

BEGIN {
	use Getopt::Long;
	use File::Temp;
	use JSON qw(decode_json encode_json);
}

# options
my %opt;
my $result;
my $error = 0;
# general config vars
my $postfix_config_default = '/etc/postfix';
my $postfix_config_master = '';
my $state_folder = '/var/local/zabbix/';
my $json_tmp_file = $state_folder.'zabbix-postfix.get-spool.tmp.json';
my $syslog_name;
my $queue_directory;
my @postfix_order = ();
my %postfix_settings = ();
my $value_target_all = 'all';
# option flags
my $multi_instance_enabled = 0;
# for all the settings
my @queue_folders = ('deferred', 'active', 'maildrop', 'incoming', 'corrupt', 'hold');
my @master_values = ('deferred', 'active', 'maildrop', 'incoming', 'corrupt', 'hold');
# parse strings
my $msg;
my $value;
my $STATE;
# return value hash
my $values;
# debug/test
my $debug = 0;
my $test = 0;

# METHOD: init_values
# PARAMS: prefix (all or syslog name)
# RETURN: none
# DESC  : inits the values list
sub init_values
{
	my ($prefix) = @_;
	# initialize the values hash
	foreach my $_val (@master_values) {
		$values->{$prefix}->{$_val} = 0;
	}
}

# METHOD: get_syslog_name
# PARAMS: config folder
# RETURN: syslog name
# DESC  : sets the syslog name from syslog_name or multi_instance_name
sub get_syslog_name
{
	my ($postfix_config) = @_;
	my $syslog_name;
	if (-d $postfix_config) {
		$syslog_name = `/usr/sbin/postconf -c $postfix_config -h syslog_name 2>/dev/null`;
		chomp $syslog_name;
		if ($syslog_name =~ /^\$\{/) {
			# if we have multi instance enabled and we have a multi_instance_name, use this, else fall back to syslog name
			my $msg = `/usr/sbin/postconf -c $postfix_config -h multi_instance_name 2>/dev/null`;
			chomp $msg;
			if ($msg) {
				$syslog_name = $msg;
			} else {
				# syslogname can be dynamic set with ${, if this is the case split with : and get last part, strip out any {} left over
				# sample: ${multi_instance_name?{$multi_instance_name}:{postfix}}
				$syslog_name = (split(/:/, $syslog_name))[1];
				$syslog_name =~ s/[\{\}]//g;
			}
		}
	}
	return $syslog_name;
}

# command line options
$result = GetOptions(\%opt,
	'config|c=s' => \$postfix_config_master,
	'debug' => \$debug,
	'test' => \$test,
	'h|help|?' # just help
) || exit 1;

if ($opt{'help'}) {
	print "HELP MESSAGE:\n";
	print "-c|--config: override default location for postfix config (/etc/postfix)\n";
	print "--debug: debug output (not json encoded default output)\n";
	print "--test: Do not write logtail or state files\n";
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
	$error = 1;
}
# check that state folder is accessable
if (! -w $state_folder) {
	print "Cannot find or access state folder: ".$state_folder."\n";
	$error = 1;
}
# exit on error
if ($error) {
	exit 0;
}

# ###########################
# [MASTER]
# set syslog name
$syslog_name = get_syslog_name($postfix_config_master);
if (!$syslog_name) {
	return '{"error":"No syslog name could be found"}';
	exit 1;
}
# get queue directory
# postconf -c /etc/postfix "queue_directory"
$queue_directory = `/usr/sbin/postconf -c $postfix_config_master -h queue_directory 2>/dev/null`;
chomp $queue_directory;
# push into arrays for loop runs
push(@postfix_order, $syslog_name);
# hash looku with syslog name
$postfix_settings{$syslog_name} = {
	'config' => $postfix_config_master,
	'queue_directory' => $queue_directory
};
# init all values
init_values($value_target_all);
# ###########################

# ###########################
# [MULTI INSTANCE]
# check if the config is part of a mult instance group
$msg = `/usr/sbin/postconf -c $postfix_config_master -h multi_instance_enable 2>/dev/null`;
chomp $msg;
if ($msg =~ /yes/i) {
	$multi_instance_enabled = 1;
	# init the master (controller with the original syslog name)
	init_values($syslog_name);
	# list the postmulti entries and get config folder and name and status
	# [multi name] [group name] [active] [config folder]
	# [TODO]
	# get instance directories
	$msg=`/usr/sbin/postconf -c $postfix_config_master -h multi_instance_directories 2>/dev/null`;
	chomp $msg;
	# split them up, we need that for any further check below
	my @multi_instance_postfix_configs = split(/\s+/, $msg);
	foreach my $multi_instance_postfix_config (@multi_instance_postfix_configs) {
		# get syslog prefix name
		my $multi_instance_syslog_name = get_syslog_name($multi_instance_postfix_config);
		# if we cannot find any valid postfix config there, remove this entry from the posfix_configs
		# [TODO]
		if ($multi_instance_syslog_name) {
			push(@postfix_order, $multi_instance_syslog_name);
			# write config
			$postfix_settings{$multi_instance_syslog_name}{'config'} = $multi_instance_postfix_config;
			# we need to get the queue directories for those multi instances
			$msg = `/usr/sbin/postconf -c $multi_instance_postfix_config -h queue_directory 2>/dev/null`;
			chomp $msg;
			$postfix_settings{$multi_instance_syslog_name}{'queue_directory'} = $msg;
			# INIT the value list for those too
			init_values($multi_instance_syslog_name);
		}
	}
}
# ###########################

# ###########################
# QUEUE DIRECTORY CONTENT COUNT
# we need to check if we can access the queue directory as the user we are running
# if if not, try sudo for find, if this is not set we skip the first part
# THIS is not mandatory count, only for hold/maildrop/incoming
foreach my $_syslog_name (@postfix_order) {
	$queue_directory = $postfix_settings{$_syslog_name}{'queue_directory'};
	foreach my $queue_folder (@queue_folders) {
		my $_queue_folder = $queue_directory.'/'.$queue_folder.'/';
		if (-d $_queue_folder) {
			$value = `sudo find $_queue_folder -type f | wc -l`;
			chomp $value;
			# write values
			$values->{$value_target_all}->{$queue_folder} += $value;
			if ($multi_instance_enabled) {
				$values->{$_syslog_name}->{$queue_folder} += $value;
			}
		}
	}
}
# ###########################

# ###########################
# DATA OUTPUT
# debug or live output
if ($debug) {
	foreach my $key (sort keys %$values) {
		foreach my $_key (sort keys %{$values->{$key}}) {
			print "[$key] $_key: ".$values->{$key}->{$_key}."\n";
		}
	}
} else {
	my $_json_string = encode_json($values);
	# write file to the state directory if we have multiple hosts enabled
	if ($multi_instance_enabled) {
		$STATE = File::Temp->new(DIR => $state_folder, UNLINK => 0);
		print $STATE $_json_string;
		close $STATE;
		rename($STATE->filename, $json_tmp_file);
	}
	print $_json_string;
}
# ###########################

# __END__
