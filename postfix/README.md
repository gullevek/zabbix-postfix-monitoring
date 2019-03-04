Postfix Monitoring for Zabbix
=============================

All templates are created for Zabbix 4.0 and test with Debian Postfix

There are three templates
* Template App Postfix Simple
* Template App Postfix Detail [auto includes Postfix Simple]
* Template App Postfix Mail Statistics

## General settings

### Software needed

All discovery scripts return JSON and so the perl JSON module needs to be installed. In debian
```
apt install libjson-perl
```
For RPM based it is
```
yum install perl-JSON
```

The statistics scripts also needs logtail installed
```
apt install logtail
```
For RPM based it is in the package logcheck
```
yum install logcheck
```

### Postfix setup

For the multi instance discovery the correct alternate config directories have to be set. In case of only one instance the below one is enough

```
alternate_config_directories = /etc/postfix
```

For Multi Instance setups this config parameter has to hold all the config folders for all the active multi instances.

For example
```
alternate_config_directories = /etc/postfix /etc/postfix-mi-a /etc/postfix-mi-b
```

### Folder setup [Statistics]

For the statistics there needs to be a folder for storing temporary data (json, stats):

```
mkdir /var/local/zabbix
chown zabbix.zabbix /var/local/zabbix
```

The following files will be stored there

| File | Description |
| ---- | ----------- |
| zabbix-postfix.get-log.logtail | logtail position information |
| zabbix-postfix.get-log.state | postfix sent email size temporary information |
| zabbix-postfix.get-log.tmp.json | Postfix log stats in JSON format are written to this file for reading in multi instance postfix installs |
| zabbix-postfix.get-queue.tmp.json | Postfix queue stats in JSON format are written to this file for reading in multi instance postfix installs |
| zabbix-postfix.get-spool.tmp.json | Postfix spool stats in JSON format are written to this file for reading in multi instance postfix installs |

### File access

The following files will be acceessed

| Script | File |
| ------ | ---- |
| Running check | [postfix spool]/run/master.pid |
| Statistics | /var/log/[mail log] |
| Statistcis | [postfix spool]/incoming|maildrop|corrupt|deferred|active|hold/* |

As most commands are run with sudo flag the following sudo entry is needed.
in /etc/suders.d/zabbix
```
# for postfix running
zabbix ALL = (ALL) NOPASSWD: /bin/cat /*/pid/master.pid
# for postfix stats
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/deferred/*
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/active/*
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/maildrop/*
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/incoming/*
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/corrupt/*
zabbix ALL = (ALL) NOPASSWD: /usr/bin/find /*/hold/*
```

The statistics script needs access to the mail.log file. The simplest way is to add zabbix to the adm user (in Debian)

```
usermod -G adm zabbix
```

For other distributions it has to be checked under which user and group the mail log files are created (/etc/rsyslog.conf)

Debian has
```
$FileOwner root
$FileGroup adm
$FileCreateMode 0640
$DirCreateMode 0755
$Umask 0022
```

OR an additional line can be added to the sudo zabbix file
```
zabbix ALL = (ALL) NOPASSWD: /usr/sbin/logtail -f /var/log/* -o *
```

The script will try to fall back to the sudo style read in case all other options fail. In case the sudo style is used the zabbix-postfix.logtail file is owned by root.

### Zabbix agent config

On a very high load system the default script run time of 3 seconds might be too slow. In case of script timeouts the parameter
```
Timeout=30
```
can bet set to eg 30 seconds (the maximum value) in the /etc/zabbix/zabbix_agentd.conf to limit the possibility of timeouts

### Templates and Value Mapping

The file value_mapping/value_mapping_postfix.xml needs to be imported first in the "Administration>General>Value Mapping" Page

The following templates exists

| Template File | Description | Note |
| ------------- | ----------- | ---- |
| template_app_postfix_simple.xml | Template App Postfix Simple | |
| template_app_postfix_detail.xml | Template App Postfix Detail | Needs the simple template imported first |
| template_app_postfix_mail_statistics.xml | Template App Postfix Mail Statistics | |

### All Macros in the Zabbix Templates

| Macro | Value | Description |
| ----- | ----- | ----------- |
| {$POSTFIX_CONFIG} | /etc/postfix | Location of the master postfix config files |
| {$POSTFIX_SCRIPT_PATH} | /etc/zabbix/scripts/ | Location for the perl backend scripts |
| {$POSTFIX_USER} | postfix | User under which the postfix processes are running |
| {$POSTFIX_LOG} | /var/log/mail.log | The main mail log file |

### Script files

| File | Description |
| ---- | ----------- |
| postfix_running.pl | Checks the master PID file if the postfix is running with this PID, also used for mult instance checks |
| postfix_multi_instance_process_memory.pl | Per multi instance process and memory count |
| postfix_get_data.pl | Collects all statistics data for single or multi instance |
| postfix_multi_instance_get_data.pl | Collects only multi instance statistics from the temp json file |
| postfix_multi_instance_discovery.pl | Discovers multi instance postfix |

### UserParameter file

The userparameter_postfix.conf file needs to be copied into the zabbix userparameter config folder usualy located in /etc/zabbix/zabbig_agentd.conf.d/

# Template App Postfix Simple

Monitors memory usage and number of all processes running as the postfix user.
Triggers alert if no processes as this user run.
Also checks if the master postfix PID is actually running and triggers alert.
Has discovery rule for checking multi instance postfix setups to monitor them via the master PID file

## Setup

### Macros

The following macros are defined and need to be adapted
* {$POSTFIX_CONFIG}
* {$POSTFIX_SCRIPT_PATH}
* {$POSTFIX_USER}

### sudo file

The following line must be present for the PID running check
```
zabbix ALL = (ALL) NOPASSWD: /bin/cat /*/pid/master.pid
```

### script files

The following files are used
* postfix_multi_instance_discovery.pl
* postfix_running.pl

## Checks

The script checks overall number of running processes and the memory used by all those processes.

## Triggers

There are two triggers. One that alerts if no process is found running under the postfix user. And the second trigger is based on a detailed PID check. This trigger is also setup for each found multi instance postfix.

# Template App Postfix Detail

Inherits the Postfix Simple and so all settings above need to be applied. No further changes are needed.

Not that this template also checks for multi instance postfix and sets up number of processes and memory used. Memory used is based on the VSZ (Virtual Memory Size) and this might be a bit off.

## Checks

This template checks for all detail programs that get spawned by postfix master process.
* Anvil
* Bounce
* Cleanup
* Flush
* Local
* Pickup
* Queue Manager (qmgr)
* Shared Cache (scache)
* Show Queue (showq)
* SMTP Daemon (smtpd)
* SMTP Runner (smtp)
* TLS Manager (tlsmgr)
* Trivial Rewrite (trivial-rewrite)
* Verify
* Virtual

It logs number for running processes and memory used for all postfixes and multi instance postfixes if running.

# Template App Postfix Mail Statistics

This template checks for detail information in the spool folders, the current mail queue and log file. It has a discovery rule for multi instance postfix

## Setup

All the described setup steps need to be applied for this, all Macros must be set.

### Macros

The following macros are defined and need to be adapted
* {$POSTFIX_CONFIG}
* {$POSTFIX_SCRIPT_PATH}
* {$POSTFIX_USER}
* {$POSTFIX_LOG}

### script files

The following files are used
* postfix_multi_instance_discovery.pl
* postfix_get_data.pl
* postfix_multi_instance_get_data.pl

## Checks

The following things are checked

| Name | Sub Of | Source | Description |
| ---- | ------ | ------ | ----------- |
| Active | | Queue | All current active mail sendings |
| Bounce | | Log | All bounced mails |
| 550 Invalid recipient | Bounce | Log | User could not be found on target server |
| 551 User Unknown | Bounce | Log | User could not be found on target server, or unauthorized user |
| 552 Too much data | Bounce | Log | mail too big
| 553 Invalid User | Bounce | Log | User name is invalid (eg non valid ascii data) |
| 554 General Error | Bounce | Log | General bounce errors |
| other error | Bounce | Log | Any bounce that does not match above rules |
| Corrupt | | Spool | |
| Deferred | | Queue | Currently not sendable, but will retry |
| 421: Refused to talk to me | Deferred | Queue | |
| 450: Delivery currently denied | Deferred | Queue | |
| 451: Delivery temporary suspended (graylisting) | Deferred | Queue | |
| 452: User over quota | Deferred | Queue | |
| 454: Relay access denied | Deferred | Queue | |
| 554: IP temporary blocked | Deferred | Queue | |
| Cannot start TLS | Deferred | Queue | |
| Connection refused | Deferred | Queue | |
| Connection timed out | Deferred | Queue | |
| General 4.x error | Deferred | Queue | Any other Error 4xx that does not match 4x rules above |
| Host or domain name not found | Deferred | Queue | |
| Lost connection with server | Deferred | Queue | |
| Mail service refused | Deferred | Queue | |
| No route to host | Deferred | Queue | |
| Read timeout | Deferred | Queue | |
| other | Deferred | Queue | Any deferred error that does not match above rules |
| delivered volume (bytes) | | Log | Sucessful sent mail volume in bytes |
| Expired | | Log | Mails that were flagged as expired |
| Hold | | Queue | Mails currently flagged as on hold |
| Incoming | | Spool | Incoming mails |
| Maildrop | | Spool | |
| Messages in queue | | Queue | Number of messages in postfix queue |
| Messages in queue size (bytes) | | Queue | Size of message in postfix queue in bytes |
| Reject | | Log | Mails that were rejected before deliver (local side) |
| 454 Relay access denied | Reject | Log | Local relay not possible |
| 550 Recipient address rejected | Reject | Log | Local user could not be found |
| other | Reject | Log | Any other reject error that does not match above rules |
| sent | | Log | Number for successful sent messages |
