microbosh-simple-backup
=======================

Simple backup script for a microbosh instance

About this microbosh-simple-backup
==================================

Warning! This information is about how to perform a manual recover 
of a bosh server, not about howto clone a bosh server.

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
    - `# /var/vcap/packages/postgres/bin/pg_dump --clean --create /var/vcap/store/postgres_$(date '+%Y%m%d%H%M%S').dump.$DB`
  3. Stop the postgresql daemon:
    - `# sudo /var/vcap/bosh/bin/monit stop postgres`
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


The script uses logs almost everything on _/var/log/scripts_ and also includes a copy of
this logfile within the output tar file.

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
  * `# sudo /var/vcap/bosh/bin/monit stop all`
7. On the bosh server, check that everything is started
  * `# sudo /var/vcap/bosh/bin/monit summary`
8. On the bosh server, start bosh agent
  * `# sudo /usr/bin/sv start agent`

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

