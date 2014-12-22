microbosh-simple-backup
=======================

Simple backup script for a microBOSH instance

About microbosh-simple-backup
=============================

Warning! This information is about how to perform a manual recover 
of a bosh server.

Assumptions:

 * bosh-deployments.yml is saved and up-to-date
 * micro_bosh.yml is saved and up-to-date.

In theory the blobstore is not needed, as it is going to be populated 
from the release you used to deploy, but it makes it much easier 
if that data is lost, the director still thinks it is available, and you 
have to recover from that by reconstructing the blobstore and updating 
the blob ids in the bosh database.

Setup
=====

The script works by reading a configuration file with some variables. You can pass
the configuration file as an argument (`-c`), but the script is able to read
it automatically if one exists with the same name as the program (except the suffix).

So, by creating a links to the script and multiple configuration files with
the same name (only changing the sufix `.sh` into `.conf`) and using different 
variables, is possible to backup different microBOSH instances.

After defining the configuration file and creating a link to the program,
you have to run the program with the argument `setup`. By doing this, the program 
will copy the _$SSH_PUBLIC_KEY_ and create the file `/etc/sudoers.d/backup` to allow        
the execution of some commands with sudo.

```
# ./microbosh-simple-backup-test.sh setup
--microbosh-simple-backup-test.sh 2014-12-21 01:19:52: Creating folders ...
--microbosh-simple-backup-test.sh 2014-12-21 01:19:52: Copying public key to 10.230.0.22 ... 
/usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
/usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
vcap@10.230.0.22's password: 

Number of key(s) added: 1

Now try logging into the machine, with:   "ssh 'vcap@10.230.0.22'"
and check to make sure that only the key(s) you wanted were added.

--microbosh-simple-backup-test.sh 2014-12-21 01:19:59: Creating sudoers file ...
vcap@10.230.0.22's password: 
[sudo] password for vcap: c1oudc0w
--microbosh-simple-backup-test.sh 2014-12-21 01:20:16: Testing connection: 
The Monit daemon 5.2.4 uptime: 29m 

Process 'nats'                      running
Process 'redis'                     running
Process 'postgres'                  running
Process 'powerdns'                  running
Process 'blobstore_nginx'           running
Process 'director'                  running
Process 'worker_1'                  running
Process 'worker_2'                  running
Process 'worker_3'                  running
Process 'director_scheduler'        running
Process 'director_nginx'            running
Process 'health_monitor'            running
System 'system_bm-e0bcbfab-fd07-4fe7-b110-675e27a85225' running
```

Run the backup
==============

```
# ./microbosh-simple-backup-test.sh backup
--microbosh-simple-backup-test.sh 2014-12-21 01:30:12: Checking monit processes ... ok (13 running)
--microbosh-simple-backup-test.sh 2014-12-21 01:30:13: Stopping bosh processes  ........ done
--microbosh-simple-backup-test.sh 2014-12-21 01:30:30: Starting DB backup. Starting processes ......... done
--microbosh-simple-backup-test.sh 2014-12-21 01:30:49: Dumping database bosh ...  done
--microbosh-simple-backup-test.sh 2014-12-21 01:30:50: Stopping DB processes ..... done!
--microbosh-simple-backup-test.sh 2014-12-21 01:31:05: Stopping bosh agent ... ok
--microbosh-simple-backup-test.sh 2014-12-21 01:31:07: Copying files with rsync ... done!
--microbosh-simple-backup-test.sh 2014-12-21 01:31:07: Starting bosh agent ... ok
--microbosh-simple-backup-test.sh 2014-12-21 01:31:08: Starting monit processes ... done
--microbosh-simple-backup-test.sh 2014-12-21 01:31:25: Cleaning temp files and copying logs ... end
```

If something went wrong it will finish with an error (return code not 0) and
it will show the error log. Moreover, the program only performs the backup if 
all monit services are in running state (monit summary), avoiding to create
non consistent backups or running two process simultaneously.

The script logs almost everything on _/var/log/scripts_ and also includes
a copy of this logfile within the output tar file.

How the backups are done
========================

The script just performs those steps (in order) using the variables
which are defined in the configuration file:

1. Logon in the microBosh VM with the parameters from the configuration file:
  * `# ssh $USER@$HOST`
2. Stop all bosh jobs,daemons and processes:
  * `# sudo /var/vcap/bosh/bin/monit stop all`
3. Wait for the termination of all processes
  * `# sudo /var/vcap/bosh/bin/monit summary`
4. Stop the bosh agent
  * `# sudo /usr/bin/sv stop agent`
5. If `$DBS` is not empty:
  1. Start the postgresql daemon:
    - `# sudo /var/vcap/bosh/bin/monit start postgres`
  2. Perform a db dump with pg_dumpall if `$DBS == _all_`
    - `# /var/vcap/packages/postgres/bin/pg_dumpall --clean -f /var/vcap/store/postgres_$(date '+%Y%m%d%H%M%S').dump.all`
    otherwise, it will dump looping with each db with pg_dump:
    - `# /var/vcap/packages/postgres/bin/pg_dump --create /var/vcap/store/postgres_$(date '+%Y%m%d%H%M%S').dump.$DB`
  3. Stop all daemons again:
    - `# sudo /var/vcap/bosh/bin/monit stop all`
6. From your local server: rsync /var/vcap/store using vcap user and the RSYNC_LIST
  * `# rsync -arzhv --delete --include-from="RSYNC_LIST" $USER@$HOST:/var/vcap/store/ $CACHE/`
7. On the bosh server, start all monit services
  * `# sudo /var/vcap/bosh/bin/monit start all`
8. On the bosh server, start bosh agent
  * `# sudo /usr/bin/sv start agent`
9. On the bosh server, remove database dumps (if exists)
  * `# rm -f /var/vcap/store/postgres_*`
10. On your local server, create a tgz file from the cache
  * `# tar -zcvf $OUTPUT $CACHE`

Recovering bosh
===============

If you are using the same version for the stemcell, those steps should be enough.
Otherwise, in case of problems, there is a db dump with all the information.

1. Logon using vcap (for example)
  * `# ssh $USER@$HOST`
2. Stop all bosh processes
  * `# sudo /var/vcap/bosh/bin/monit stop all`
3. Wait for finishing all processes
  * `# sudo /var/vcap/bosh/bin/monit summary`
4. Stop microBosh agent
  * `# sudo /usr/bin/sv stop agent`
5. From your local server, rsync all the data cached from the latest backup,
  otherwise, you can copy a tgz file and uncompress it manually on the bosh
  server:
  * `# rsync -arzhv --delete $CACHE/ $USER@$HOST:/var/vcap/store/`
  or by coping a tgz file:
  * `# rsync -arzhv BACKUP.tgz $USER@$HOST:/var/vcap/store/`
  and go to bosh server ...
6. On the bosh server, start all bosh processes
  * `# sudo /var/vcap/bosh/bin/monit start all`
7. On the bosh server, start bosh agent
  * `# sudo /usr/bin/sv start agent`
8. On the bosh server, check that everything is started
  * `# sudo /var/vcap/bosh/bin/monit summary`

By doing those operations, you should be able to recover everything,
if that does not work, then you will need more hacks.

Be carefull, because the database contains references like: vm_cid, 
uuid, etc. so depending on the disaster situation you will need to 
change the uuid, vm_cid, the disk uuid and path on the dumped database 
before importing it (please have a look and compare with the 
bosh-deployments file).

In case you have a DB dump with from all postgres, in order to extract 
the bosh database from the dump, you can type:

```
# awk '/^\\connect bosh/ {flag=1;next} /^\\connect/ {flag=0} flag { print }' < postgres_*.dump.all > bosh.sql
```

After that you can edit the file, or just import it on another DB and
work with both databases.

```
# /var/vcap/packages/postgres/bin/createdb bosh-backup
# /var/vcap/packages/postgres/bin/psql -f bosh.sql bosh-backup
# /var/vcap/packages/postgres/bin/psql
```

