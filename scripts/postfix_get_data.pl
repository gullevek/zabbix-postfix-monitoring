#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE  : 2019/3/1
# UPDATE: 2019/3/1
# DESC  : gets all statisics data
#         * checks spool folder for the following counts
#           - maildrop
#           - incoming
#           - corrupt
#         * checks mail queue for
#           - deferred
#           - active
#           - hold
#           - messages in queue (all)
#           - kbyte size of mails in queue (all)
#           - detail report on deferred
#         * checks log file for
#           - sent OK
#           - bounced
#           - rejected
#           - sent messges size (volume)
#           - detail reports for bounces/rejects

use strict;
use warnings;

BEGIN {
	use Getopt::Long;
	use File::Temp;
	use JSON qw(decode_json encode_json);
}

# constant
# exire for queue is 6 days
use constant queue_id_expiry => 6 * 3600;
# options
my %opt;
my $result;
my %valid_read_source = ('all' => 1, 'log' => 1, 'queue' => 1, 'spool' => 1);
my $read_source; # core flag with queue|log|spool|all
my $error = 0;
# general config vars
my $postfix_config_default = '/etc/postfix';
my $postfix_config_master = '';
my $mail_log_default = '/var/log/mail.log';
my $mail_log;
my $state_folder = '/var/local/zabbix/';
my $json_tmp_file = $state_folder.'zabbix-postfix.get-##DATA##.tmp.json';
my $logtail_storage = $state_folder.'zabbix-postfix.get-log.logtail';
my $state_file = $state_folder.'zabbix-postfix.get-log.state';
my $syslog_name;
my $syslog_name_regex;
my %syslog_regex = ();
my $queue_directory;
my $value_target_all = 'all';
my $value_target;
my $logtail_prefix = ''; # possible sudo prefix for logtail
my $postfix_version;
# for all the settings
my @postfix_order = ();
my %postfix_settings = ();
# option flags
my $multi_instance_enabled = 0;
# lists
# SPOOL
my @queue_folders = ('deferred', 'active', 'maildrop', 'incoming', 'corrupt', 'hold');
# QUEUE
my @deferred_order = ('tlsfailed', 'crefused', 'ctimeout', 'rtimeout', 'nohost', 'msrefused', 'noroute', 'lostc', 'ipblocked', 'err421', 'err450', 'err451', 'err452', 'err454', 'err4');
my %deferred_details = (
	'tlsfailed' => qr/Cannot start TLS/,
	'crefused' => qr/Connection refused/,
	'ctimeout' => qr/(Connection timed out|timed out while)/,
	'rtimeout' => qr/read timeout/,
	'nohost' => qr/Host (or domain name )?not found/,
	'msrefused' => qr/server refused mail service/,
	'noroute' => qr/No route to host/,
	'lostc' => qr/lost connection with/,
	'ipblocked' => qr/refused to talk to me: 554/, # 421 -> blocked ip
	# sub detail
	'err421' => qr/(refused to talk to me: 421|: 421(\ |\)|\-))/, # connection refused
	'err450' => qr/: 450( |\-)/, # delivere warning (address rejected)
	'err451' => qr/: 451( |\-)/, # temp error (eg gray listing with address rejected)
	'err452' => qr/: 452( |\-)/, # over quota
	'err454' => qr/: 454( |\-)/, # relay access denied
	# error 4 catch all
	'err4' => qr/said: 4/,
);
# LOG
my @bounce_order = ('550invalid', '551noauth', '552toobig', '553nonascii', '554error', 'nullmx');
my %bounce_details = (
	'550invalid' => qr/said: 550( |\-)/,
	'551noauth' => qr/said: 551( |\-)/,
	'552toobig' => qr/said: 552( |\-)/,
	'553nonascii' => qr/said: 553( |\-)/,
	'554error' => qr/said: 554( |\-)/,
	'nullmx' => qr/ \(nullMX\)/,
);
my @reject_order = ('454norelay', '550nouser');
# COMBINED BASE
my %master_values_list = (
	'log' => ['sent', 'bounce', 'bounce_other', 'reject', 'reject_other', 'expired', 'delivered_volume'],
	'spool' => ['deferred', 'active', 'maildrop', 'incoming', 'corrupt', 'hold'],
	'queue' => ['deferred', 'deferred_other', 'active', 'hold', 'queue_messages', 'queue_size']
);
my @master_values = ();
# parse strings
my $msg;
my $value;
my $jhash;
my $found = 0;
my $STATE;
# values interim
my %volumes_per_queue_id = ();
my $serialized_volumes_queue;
# return value hash
my $values;
# debug/test
my $debug = 0;
my $test = 0;
my $cleanup = 0;

# ###########################
# [FUNCTIONS]
# METHOD: init_values
# PARAMS: prefix (all or syslog name)
# RETURN: none
# DESC  : inits the values list
sub init_values
{
	my ($prefix, $target) = @_;
	# initialize the values hash
	foreach my $_val (@master_values) {
		$values->{$prefix}->{$_val} = 0;
		# only for queue
		if (($target eq 'queue' || $target eq 'all') && $_val eq 'deferred') {
			foreach my $__val (@deferred_order) {
				$values->{$prefix}->{$_val.'_'.$__val} = 0;
			}
		}
		# only for log
		if ($target eq 'log' || $target eq 'all') {
			if ($_val eq 'bounce') {
				foreach my $__val (@bounce_order) {
					$values->{$prefix}->{$_val.'_'.$__val} = 0;
				}
			}
			if ($_val eq 'reject') {
				foreach my $__val (@reject_order) {
					$values->{$prefix}->{$_val.'_'.$__val} = 0;
				}
			}
		}
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
# ###########################

# ###########################
# [COMMAND OPTIONS]
# command line options
$result = GetOptions(\%opt,
	'read|r=s' => \$read_source,
	'config|c=s' => \$postfix_config_master,
	'log|l=s' => \$mail_log,
	'cleanup' => \$cleanup,
	'debug' => \$debug,
	'test' => \$test,
	'h|help|?' # just help
) || exit 1;

if ($opt{'help'}) {
	print "HELP MESSAGE:\n";
	print "-r|--read <all|spool|log|queue>: what source to read and print\n";
	print "-c|--config <path>: override default location for postfix config (/etc/postfix)\n";
	print "-l|--log <file>: override default location for mail log (/var/log/mail.log)\n";
	print "--cleanup: remove state & logtail files after they have been used (reset state)\n";
	print "--debug: debug output (not json encoded default output)\n";
	print "--test: Do not write logtail or state files\n";
	exit 1;
}

# Abort if not spool/queue/log is given
# combined sets are allowed
# if (!$read_source || !grep { $_ eq $read_source } ['all', 'spool', 'queue', 'log']) {
if (!$read_source || !$valid_read_source{$read_source}) {
	print "The read source is not set or not valid flag given (all, spool, queue, log)\n";
	$error = 1;
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
if ($read_source && ($read_source eq 'all' || $read_source eq 'log')) {
	# check that mail log exists
	if (!$mail_log) {
		$mail_log = $mail_log_default;
	}
	if (! -f $mail_log) {
		print "Cannot open mail log at: ".$mail_log."\n";
		$error = 1;
	}
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

# ###########################
# [MASTER]
# set master element list based on read source flag
if ($read_source eq 'all') {
	foreach my $_key (keys %master_values_list) {
		push(@master_values,  @{$master_values_list{$_key}});
	}
} else {
	push(@master_values, @{$master_values_list{$read_source}});
}
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
init_values($value_target_all, $read_source);
# get postfix version
$postfix_version = `/usr/sbin/postconf -c $postfix_config_master -h mail_version 2>/dev/null`;
chomp $postfix_version;
# ###########################

# ###########################
# [MULTI INSTANCE]
# check if the config is part of a mult instance group
$msg = `/usr/sbin/postconf -c $postfix_config_master -h multi_instance_enable 2>/dev/null`;
chomp $msg;
if ($msg =~ /yes/i) {
	$multi_instance_enabled = 1;
	# init the master (controller with the original syslog name)
	init_values($syslog_name, $read_source);
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
			init_values($multi_instance_syslog_name, $read_source);
		}
	}
}
# ###########################

# ###########################
# QUEUE DIRECTORY CONTENT COUNT
if ($read_source eq 'spool') {
	# we need to check if we can access the queue directory as the user we are running
	# if if not, try sudo for find, if this is not set we skip the first part
	# full count for all core folders (is faster then do the queue count)
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
}
# ###########################

# ###########################
# MAIL QUEUE COUNT AND SIZE [JSON]
if ($read_source eq 'queue') {
	my $row_ok = 0;
	my $row_count = 0;
	my $postqueue_option = '-j';
	# check if postqueue has flag -j (Version >=3.1)
	if ($postfix_version =~ /^[12]\./ || $postfix_version =~ /^3\.0/) {
		$postqueue_option = '-p';
	}
	# if not we have to use the old read style
	foreach my $_syslog_name (@postfix_order) {
		my $postfix_config = $postfix_settings{$_syslog_name}{'config'};
		open(FH, "/usr/sbin/postqueue -c $postfix_config $postqueue_option|") || die ("Can't open postqueue handler: ".$!."\n");
		while (<FH>) {
			chomp $_;
			if ($postqueue_option eq '-j') {
				$jhash = decode_json($_);
				# for json output, it is alwys OK
				$row_ok = 1;
			} else {
				# old style is n lines and empty line
				# first line is ID + active/hold/deferred status and size
				if ($row_count == 0) {
					if ($_ =~ /^[0-9A-Fa-z]{10,}([\*\!])?\s+(\d+)/) {
						# * = active, ! = hold, empty = deferred
						if ($1 eq '*') {
							$jhash->{'queue_name'} = 'active';
						} elsif ($1 eq '!') {
							$jhash->{'queue_name'} = 'hold';
						} else {
							$jhash->{'queue_name'} = 'deferred';
						}
						# the mail size
						$jhash->{'message_size'} = $2;
					}
				} else {
					# if it is deferred add new entry
					if ($jhash->{'queue_name'} eq 'deferred') {
						# if not EMPTY line and not a line with leading spaces and any email like address
						if (length($_) > 0 && $_ !~ /^\s+.*@.*/) {
							# store the deferred reason here
							push(@{$jhash->{'recipients'}}, {'delay_reason' => $_});
						}
					}
				}
				$row_count ++;
				# if the line is empty, we reached end of record, process the data
				if (!length($_)) {
					$row_ok = 1;
				}
			}
			if ($row_ok) {
				# size and message count
				$values->{$value_target_all}->{'queue_size'} += $jhash->{'message_size'};
				$values->{$value_target_all}->{'queue_messages'} ++;
				if ($multi_instance_enabled) {
					$values->{$_syslog_name}->{'queue_size'} += $jhash->{'message_size'};
					$values->{$_syslog_name}->{'queue_messages'} ++;
				}
				# if queue is deferred, count errors, if active or hold do only normal count
				if ($jhash->{'queue_name'} eq 'active') {
					$values->{$value_target_all}->{'active'} ++;
					if ($multi_instance_enabled) {
						$values->{$_syslog_name}->{'active'} ++;
					}
				} elsif ($jhash->{'queue_name'} eq 'hold') {
					$values->{$value_target_all}->{'hold'} ++;
					if ($multi_instance_enabled) {
						$values->{$_syslog_name}->{'hold'} ++;
					}
				} elsif ($jhash->{'queue_name'} eq 'deferred') {
					$values->{$value_target_all}->{'deferred'} ++;
					if ($multi_instance_enabled) {
						$values->{$_syslog_name}->{'deferred'} ++;
					}
					# detailed deferred count
					foreach my $recipient (@{$jhash->{'recipients'}}) {
						$found = 0;
						# match up any error reason here
						foreach my $deferred_key (@deferred_order) {
							if ($deferred_details{$deferred_key} && $recipient->{'delay_reason'} =~ $deferred_details{$deferred_key}) {
								$values->{$value_target_all}->{'deferred_'.$deferred_key} ++;
								if ($multi_instance_enabled) {
									$values->{$_syslog_name}->{'deferred_'.$deferred_key} ++;
								}
								$found = 1;
								last; # exit the loop
							}
						}
						if (!$found) {
							$values->{$value_target_all}->{'deferred_other'} ++;
							if ($multi_instance_enabled) {
								$values->{$_syslog_name}->{'deferred_other'} ++;
							}
						}
					}
				}
				# reset row ok and row count and the jhash for the old style print
				if ($postqueue_option eq '-p') {
					$row_ok = 0;
					$row_count = 0;
					$jhash = ();
				}
			}
		}
		close(FH);
	}
}
# ###########################

# ###########################
# MAIL LOG PARSING
if ($read_source eq 'log') {
	# uses logtail to keep position
	# for mail volume (size) we need to check that the mail was actually sent, so we keep a queue id in a storage file that we clean up after some time
	# load stored volumes_per_queue_id data and fill the var before processing log
	if (-f $state_file) {
		if (open(FH, '<', $state_file)) {
			$serialized_volumes_queue = <FH>;
			# each element
			for my $queue_item_descriptor (split(/ /, $serialized_volumes_queue || "")) {
				# has queu id = data
				(my $queue_item_id, my $queue_item_content) = split(/=/, $queue_item_descriptor);
				# each data has size + timestamp
				(my $size, my $timestamp) = split(/:/, $queue_item_content);
				# write back to current data
				$volumes_per_queue_id{$queue_item_id} = {
					size => int($size),
					timestamp => int($timestamp)
				};
			}
			close(FH);
		} else {
			# do something?
		}
	}
	# regex sub part build for syslog_name
	$syslog_name_regex = join('|', @postfix_order);
	# build all the regexes for matching
	%syslog_regex = (
		'volume' => qr/($syslog_name_regex)\/qmgr.*: ([0-9A-Fa-z]{10,}): from=.*, size=(\d+)/,
		'sent' => qr/($syslog_name_regex)\/smtp.*: ([0-9A-Za-z]{10,}): to=.*, status=sent/,
		'bounced' => qr/($syslog_name_regex)\/smtp.*: ([0-9A-Za-z]{10,}): to=.*, dsn=(.*), status=bounced \((.*)\)/,
		'reject_smtpd' => qr/($syslog_name_regex)\/smtpd.*reject: \S+ \S+ \S+ (\S+)/,
		'reject_smtpd_proxy' => qr/($syslog_name_regex)\/smtpd.*proxy-reject: \S+ (\S+)/,
		'reject_cleanup' => qr/($syslog_name_regex)\/cleanup.* reject: (\S+)/,
		'reject_cleanup_milter' => qr/($syslog_name_regex)\/cleanup.* milter-reject: \S+ \S+ \S+ (\S+)/,
		'expired' => qr/($syslog_name_regex)\/qmgr.*: ([0-9A-Fa-z]{10,}): from=.*, status=expired/
	);
	# check file mail log file is readable, if not try sudo for logtail
	if (! -r $mail_log) {
		$logtail_prefix = 'sudo ';
	}
	# if we are on a test system set test logtail storage
	if ($test) {
		$logtail_storage .= '.test';
		$state_file .= '.test'
	}
	# read log file
	open(FH, $logtail_prefix.'/usr/sbin/logtail -f '.$mail_log.' -o '.$logtail_storage.' |') || die ("Cannot open $mail_log\n");
	while (<FH>) {
		chomp;
		# find size [Feb 26 10:07:33 tako postfix-pc214/qmgr[60721]: 37F3A4C131C: from=<mailingtool@mailing-tool.tequila.jp>, size=12204, nrcpt=1 (queue active)]
		if ($_ =~ $syslog_regex{'volume'}) {
			# need $1 & $2
			if (not exists($volumes_per_queue_id{$2})) {
				$volumes_per_queue_id{$2} = {
					timestamp => time
				};
			}
			# update/reset size
			$volumes_per_queue_id{$2}->{size} = $3;
		} elsif ($_ =~ $syslog_regex{'sent'}) {
			# actaul sent data -> count up delivered volume
			$value_target = $1;
			if (exists($volumes_per_queue_id{$2})) {
				$values->{$value_target_all}->{'delivered_volume'} += $volumes_per_queue_id{$2}->{size};
				if ($multi_instance_enabled) {
					$values->{$value_target}->{'delivered_volume'} += $volumes_per_queue_id{$2}->{size};
				}
				$volumes_per_queue_id{$2}->{timestamp} = time;
				# in case of multiple deliverey of same mail, we keep the data
			}
			# sent ok
			$values->{$value_target_all}->{'sent'} ++;
			if ($multi_instance_enabled) {
				$values->{$value_target}->{'sent'} ++;
			}
		} elsif ($_ =~ $syslog_regex{'bounced'}) {
			# bounced
			$value_target = $1;
			$values->{$value_target_all}->{'bounce'} ++;
			if ($multi_instance_enabled) {
				$values->{$value_target}->{'bounce'} ++;
			}
			# bounced detail logging (error number)
			# 1. 550 (invalid user)
			# 2. 551 (not authorized)
			# 3. 552 (too big)
			# 4. 553 (non ascii not permitted)
			# 5. 554 (other delivery error)
			# 6. (nullMX) (no MX service for host)
			# 7. anything else
			$msg = $4;
			$found = 0;
			# match up any error reason here
			foreach my $bounce_key (@bounce_order) {
				if ($bounce_details{$bounce_key} && $msg =~ $bounce_details{$bounce_key}) {
					$values->{$value_target_all}->{'bounce_'.$bounce_key} ++;
					if ($multi_instance_enabled) {
						$values->{$value_target}->{'bounce_'.$bounce_key} ++;
					}
					$found = 1;
					last; # exit the loop
				}
			}
			if (!$found) {
				$values->{$value_target_all}->{'bounce_other'} ++;
				if ($multi_instance_enabled) {
					$values->{$value_target}->{'bounce_other'} ++;
				}
			}

		} elsif ($_ =~ $syslog_regex{'reject_smtpd'} ||
			$_ =~ $syslog_regex{'reject_smtpd_proxy'} ||
			$_ =~ $syslog_regex{'reject_cleanup'} ||
			$_ =~ $syslog_regex{'reject_cleanup_milter'}
		) {
			$value_target = $1;
			# rejected
			$values->{$value_target_all}->{'reject'} ++;
			if ($multi_instance_enabled) {
				$values->{$value_target}->{'reject'} ++;
			}
			# reject detail
			# 454: relay access denied
			# 550: user not found
			# other: anything else
			$msg = $2;
			if ($msg eq '454') {
				$values->{$value_target_all}->{'reject_454norelay'} ++;
				if ($multi_instance_enabled) {
					$values->{$value_target}->{'reject_454norelay'} ++;
				}
			} elsif ($msg eq '550') {
				$values->{$value_target_all}->{'reject_550nouser'} ++;
				if ($multi_instance_enabled) {
					$values->{$value_target}->{'reject_550nouser'} ++;
				}
			} else {
				$values->{$value_target_all}->{'reject_other'} ++;
				if ($multi_instance_enabled) {
					$values->{$value_target}->{'reject_other'} ++;
				}
			}
		} elsif ($_ =~ $syslog_regex{'expired'}) {
			$value_target = $1;
			# expired
			$values->{$value_target_all}->{'expired'} ++;
			if ($multi_instance_enabled) {
				$values->{$value_target}->{'expired'} ++;
			}
		}
		# error details for bounce/reject others, must have been not in a size, sent or expired group
		# for these error checks we need the queue id and we need to store the status so we don't count twice for the same
		# ALL those checks are done with postqueue (see above)
		# if we do this here, this is only for point in time and history reason
	}
	close(FH);
	# remove all expired queue IDs
	my @expired_queue_ids;
	for my $key (keys %volumes_per_queue_id) {
		if (time > $volumes_per_queue_id{$key}->{timestamp} + queue_id_expiry) {
			push(@expired_queue_ids, $key);
		}
	}
	delete(@volumes_per_queue_id{@expired_queue_ids});
	# write left over ids to serialzied data file
	$serialized_volumes_queue = join(" ", map { sprintf("%s=%s", $_, sprintf("%d:%d", $volumes_per_queue_id{$_}->{size}, $volumes_per_queue_id{$_}->{timestamp})) } keys %volumes_per_queue_id);
	# write to temp file
	$STATE = File::Temp->new(DIR => $state_folder, UNLINK => 0);
	# write to state file
	print $STATE $serialized_volumes_queue;
	close $STATE;
	# rename temp file to live file
	rename($STATE->filename, $state_file);
	# remove state/logtail position files if called with cleanup flag
	if ($cleanup) {
		unlink($logtail_storage);
		unlink($state_file);
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
		# fix target name
		$json_tmp_file =~ s/##DATA##/$read_source/;
		# if called with test, use test file
		if ($test) {
			$json_tmp_file .= '.test';
		}
		rename($STATE->filename, $json_tmp_file);
	}
	print $_json_string;
}
# ###########################

# __END__
