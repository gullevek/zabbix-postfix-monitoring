PostgreSQL Simple Monitoring
============================

Checks for processes running by the postgres master user and any pgsql client applictions.
Also checks if postgresql is running on the given default port.

## General Settings

### Setable Macros

| Macro Name | Default Value | Description |
| ---------- | ------------- | ----------- |
| {$POSTGRESQL_CLIENT} | psgl | The PostgreSQL Client name |
| {$POSTGRESQL_PORT} | 5432 | Default port on which PostgreSQL is listening |
| {$POSTGRESQL_PROCESS} | postgres | The process name under which all server processes are spawned |

For the correct name for _{$POSTGRESQL\_PROCESS}_ the following commands can be used.

First get the pid of the postmaster process
```
#> ps ax|grep postmaster
16686 ?        S      0:54 /usr/pgsql-9.4/bin/postmaster -D /var/lib/pgsql/9.4/data
```

Then run the command with the pid (in the example it is **16686**)
```
#> cat /proc/16686/status|grep "Name:"
Name:   postmaster
```

Then set the value from the field _Name:_

In the example it is **postmaster**
