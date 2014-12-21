#!/usr/bin/env bash
#
# microBosh simple backup
# (c) 2014 Jose Riguera <jose.riguera@springer.com>
# Licensed under GPLv3

# First we need to setup the Global variables, only if their default values
# are wrong for this script
DEBUG=0
EXEC_USER=$USER                # normally must be an user or $USER to avoid
                               # changuing the user automaticaly with sudo.
PROCESS_TIME_LIMIT=600
SSH='ssh -n'
SSH_OPTIONS='ConnectTimeout=30 BatchMode=yes'

# Other variables
PROGRAM=${PROGRAM:-$(basename $0)}
PROGRAM_DIR=$(cd $(dirname "$0"); pwd)
NAME=$PROGRAM
DESC="microBosh simple backup"

# Load the library and load the configuration file if it exists
REALPATH=$(readlink "$PROGRAM")
if [ ! -z "$REALPATH" ]; then
    REALPATH=$(dirname "$REALPATH")
    _COMMON="$REALPATH/_libs/_common.sh"
else
    _COMMON="$PROGRAM_DIR/_libs/_common.sh"
fi
if ! [ -f "$_COMMON" ]; then
    msg="$(date "+%Y-%m-%d %T"): Error $_COMMON not found!"
    logger -s -p local0.err -t ${0} "$msg"
    exit 1
fi
. $_COMMON

# Program variables
MONIT="sudo /var/vcap/bosh/bin/monit"
RUNIT="sudo /usr/bin/sv"
DBDUMP="/var/vcap/packages/postgres/bin/pg_dump --create"
DBDUMPALL="/var/vcap/packages/postgres/bin/pg_dumpall --clean"
RSYNC="rsync -arzhv -AX --delete "
TAR="tar -acv --acls --atime-preserve"

# Functions and procedures
set +e

# help
usage() {
    cat <<EOF
Usage:

    $PROGRAM  [-h | --help ] [-d | --debug] [-c | --config <configuration-file>] <action>

$DESC

Arguments:

   -h, --help         Show this message
   -d, --debug        Debug mode
   -c, --config       Configuration file

Action:

   backup             Perform backup
   setup              Set credentials and create folders

EOF
}


pre_start() {
    local user="$1"
    local host="$2"

    local notrunning
    local running=0
    local stopped
    local rvalue=1
    local counter
    local wait_time=$PROCESS_TIME_LIMIT

    echon_log "Checking monit processes ... "
    notrunning=$(exec_host "$user" "$host" "$MONIT summary" | awk 'NR > 2 && $3!="running" { print $2 }') 2>&1 >/dev/null
    rvalue=${PIPESTATUS[0]}
    if [ $rvalue  != 0 ]; then
        echo "failed!"
    	error_log "Error, monit summary failed. Fix it!"
        return $rvalue
    fi
    if [ ! -z ${notrunning} ]; then
        echo "failed!"
        error_log "some monit processes are not running!: ${notrunning}"
        return 1
    fi
    running=$(exec_host "$user" "$host" "$MONIT summary" | awk 'NR > 2 && $3=="running" { print $2 }' | wc -w)
    [ "${running}" == 0 ] && return 1
    echo "ok (${running} running)"
    echon_log "Stopping bosh processes  "
    exec_host "$user" "$host" "$MONIT stop all" > /dev/null
    for ((counter=0;counter<wait_time;counter++)); do
        echo -n "."
        sleep 2
        stopped=$(exec_host "$user" "$host" "$MONIT summary" | grep -e ' not monitored$' | wc -l)
        [ "$running" == "$stopped" ] && echo " done" && break
    done
    stopped=$(exec_host "$user" "$host" "$MONIT summary" | grep -e ' not monitored$' | wc -l)
    if [ "$running" != "$stopped" ]; then
 	echo " failed"
        error_log "Failed to stop monit processes ... Restarting again:"
        exec_host "$user" "$host" "$MONIT validate"
        return 1
    fi
    return 0
}



bosh_agent() {
    local user="$1"
    local host="$2"
    local action="$3"

    local rvalue=0

    if [ "${action}" == "stop" ]; then
        echon_log "Stopping bosh agent ... "
        exec_host "$user" "$host" "$RUNIT stop agent" > /dev/null
        rvalue=$?
    else
        echon_log "Starting bosh agent ... "
        exec_host "$user" "$host" "$RUNIT start agent" > /dev/null
        rvalue=$?
    fi
    if [ $rvalue != 0 ]; then
        echo "failed!"
        error_log "Failed to control bosh agent ... Validating ..."
        exec_host "$user" "$host" "$RUNIT start agent" > /dev/null
        error_log "Starting monit ..."
        exec_host "$user" "$host" "$MONIT validate" > /dev/null
        return 1
    fi
    echo "ok"
    return 0
}


post_finish() {
    local user="$1"
    local host="$2"

    local rvalue=1
    local counter
    local wait_time=$PROCESS_TIME_LIMIT

    echon_log "Starting monit processes "
    for ((counter=0;counter<wait_time;counter++)); do
        echo -n "."
        sleep 2
        exec_host "$user" "$host" "$MONIT summary" 2>&1 | head -n 1 | grep -q "uptime" >/dev/null
        rvalue=$?
        if [ $rvalue == 0 ]; then
            echo " done"
            debug_log "starting all monit processes"
            exec_host "$user" "$host" "$MONIT start all" > /dev/null 2>> $PROGRAM_LOG
            break
        fi
    done
    sleep 10
    debug_log "Summary of monit processes"
    exec_host "$user" "$host" "$MONIT summary" > /dev/null 2>> $PROGRAM_LOG
    rvalue=$?
    return $rvalue
}


db_dump() {
    local user="$1"
    local host="$2"
    local dst="$3"
    local dbs="$4"

    local rvalue=0
    local exitvalue=1
    local counter
    local running=1
    local wait_time=$PROCESS_TIME_LIMIT

    echon_log "Starting DB backup. Starting processes "
    exec_host "$user" "$host" "$MONIT start postgres" > /dev/null
    for ((counter=0;counter<wait_time;counter++)); do
        echo -n "."
        sleep 2
        exec_host "$user" "$host" "$MONIT summary" | grep postgres | grep -q ' running'
        exitvalue=$?
        [ "$exitvalue" == "0" ] && echo " done" && break
    done
    if [ "$exitvalue" != "0" ]; then
        echo " failed!"
        error_log "Failed to start postgres:"
        exec_host "$user" "$host" "$MONIT summary"
        rvalue=$exitvalue
    fi
    if echo ${dbs} | grep -q "_all_"; then
       echon_log "Dumping all databases ... "
       exec_host "$user" "$host" "sudo -- touch ${dst}.all && sudo -- chown vcap ${dst}.all" > /dev/null
       exec_host "$user" "$host" "$DBDUMPALL -f ${dst}.all" > /dev/null
       exitvalue=$?
       if [ "$exitvalue" == "0" ]; then
           echo " done"
       else
           echo " failed"
           error_log "dumping db:"
           rvalue=$exitvalue
       fi
    else
       for d in ${dbs}; do
           echon_log "Dumping database ${d} ... "
           exec_host "$user" "$host" "sudo -- touch ${dst}.${d} && sudo -- chown vcap ${dst}.${d}"
           exec_host "$user" "$host" "$DBDUMP -f ${dst}.${d} ${d}" > /dev/null
           exitvalue=$?
           if [ "$exitvalue" == "0" ]; then
               echo " done"
           else
               echo " failed"
               error_log "dumping db:"
               rvalue=$exitvalue
               break
           fi
       done
    fi
    echon_log "Stopping DB processes "
    exec_host "$user" "$host" "$MONIT stop all" > /dev/null
    for ((counter=0;counter<wait_time;counter++)); do
        echo -n "."
        sleep 2
        running=$(exec_host "$user" "$host" "$MONIT summary" | awk 'NR > 2 && $3=="running" { print $2 }' | wc -w)
        [ "$running" == "0" ] && echo " done!" && break
    done
    if [ "$running" != "0" ]; then
        echo " failed!"
        error_log "Failed to stop postgres processes:"
        exec_host "$user" "$host" "$MONIT summary"
        rvalue=$exitvalue
    fi
    sleep 5
    return $rvalue
}


rsync_files() {
    local user="$1"
    local host="$2"
    local remote="$3"
    local dst="$4"
    local filelist="$5"

    local rvalue=0
    local logfile="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S').rsync.log"
    local sshoptions=""

    echon_log "Copying files with rsync ... "
    [ ! -z "${SSH_PRIVATE_KEY}" ] && sshoptions="-i ${SSH_PRIVATE_KEY}"
    echo $RSYNC -e "ssh -l ${user} ${sshoptions}" --rsync-path="sudo rsync" --filter="merge ${filelist}" --log-file=$logfile ${user}@${host}:"${remote}" "${dst}/" >>$PROGRAM_LOG
    $RSYNC -e "ssh -l ${user} ${sshoptions}" --rsync-path="sudo rsync" --filter="merge ${filelist}" --log-file=$logfile ${user}@${host}:"${remote}" "${dst}/" >>$PROGRAM_LOG 2>&1
    rvalue=$?
    cat $logfile >> $PROGRAM_LOG
    if [ $rvalue == 0 ]; then
        echo "done!"
    else
        echo "error!"
        error_log "rsync has reported some errors"
        cat $logfile
    fi
    rm -f $logfile
    return $rvalue
}


archive() {
    local dst="$1"
    local output="$2"
    local added="$3"

    local logfile="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S').tar.log"

    echon_log "Adding extra files: "
    for f in ${added}; do
        echo -n "${f}"
        echo cp -v "${f}" "${dst}/" >>$PROGRAM_LOG
        cp -v "${f}" "${dst}/" >>$PROGRAM_LOG 2>&1 || echo -n "(failed) " && echo -n " "
    done
    echo
    echon_log "Creating tgz $output ... "
    echo $TAR -f ${output} -C ${dst} * >>$PROGRAM_LOG
    cd ${dst} && $TAR -f ${output} -C ${dst} * 2>&1 | tee -a $PROGRAM_LOG > "${logfile}"
    rvalue=${PIPESTATUS[0]}
    if [ $rvalue == 0 ]; then
        echo "done!"
    else
        echo "error!"
        cat "${logfile}"
    fi
    rm -f "${logfile}"
    return $rvalue
}


backup() {
    local user="$1"
    local host="$2"
    local dbs="$3"
    local cache="$4"
    local filelist="$5"
    local output="$6"
    local addlist="$7"

    local rvalue=0
    local exitvalue
    local remote="/var/vcap/"
    local tmpfile="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S').rsync.list"
    local dbdump="/var/vcap/store/postgres_$(date '+%Y%m%d%H%M%S').dump"
    local dbdir="${cache}/dbs/"
    local rsyncache="${cache}/vcap/"

    echo $(date '+%Y%m%d%H%M%S') > "${cache}/_date.control"
    pre_start ${user} ${host} || return 1
    debug_log "Preparing list of files ..."
    get_list "${filelist}" | tee -a $PROGRAM_LOG > ${tmpfile}
    if [ ! -z "${dbs}" ]; then
        db_dump ${user} ${host} "${dbdump}" "${dbs}"
        rvalue=$?
        if [ $rvalue == 0 ]; then
            debug_log "Adding DB backup to the list of files: "
	    echo "+ store/$(basename ${dbdump})*" | tee -a $PROGRAM_LOG >> "${tmpfile}"
        fi
    fi
    if [ $rvalue == 0 ]; then
        bosh_agent "$user" "$host" "stop"
        rvalue=$?
        if [ $rvalue == 0 ]; then
            mkdir -p "${rsyncache}"
            rsync_files ${user} ${host} "${remote}" "${rsyncache}" "${tmpfile}"
            rvalue=$?
        fi
    fi
    bosh_agent "$user" "$host" "start"
    post_finish ${user} ${host}
    exitvalue=$?
    echo $(date '+%Y%m%d%H%M%S') >> "${cache}/_date.control"
    debug_log "Removing remote dbdump ..."
    exec_host "$user" "$host" "sudo rm -f ${dbdump}*" >> $PROGRAM_LOG
    if [ $rvalue == 0 ]; then
        debug_log "Moving dbdump to final location ${dbdir} ..."
        rm -rf "${dbdir}" && mkdir -p "${dbdir}" 2>&1 | tee -a $PROGRAM_LOG
        mv "${rsyncache}/store/$(basename ${dbdump})"* "${dbdir}/" 2>&1 | tee -a $PROGRAM_LOG
        rvalue=$?
        if [ $rvalue != 0 ]; then
            error_log "moving local dabatase dumps"
        else
            if [ ! -z "${output}" ]; then
                archive "${cache}" "${output}" "$(get_list ${addlist})"
                rvalue=$?
            fi
        fi
    fi
    echon_log "Cleaning temp files and copying logs ... "
    rm -f "${cache}/"*.log
    cp -v "$PROGRAM_LOG" "${cache}/" >>$PROGRAM_LOG 2>&1
    rm -f "${tmpfile}"
    echo "end"
    [ $exitvalue != 0 ] && return $exitvalue
    return $rvalue
}


setup() {
    local user="$1"
    local host="$2"
    local cache="$3"
    local key="$4"

    local rvalue=1

    echo_log "Creating folders ..."
    mkdir -p "${cache}" | tee -a -a $PROGRAM_LOG
    rvalue=${PIPESTATUS[0]}
    if [ $rvalue == 0 ]; then
        echo_log "Copying public key to "${host}" ... "
	ssh-copy-id -i ${key} "${user}@${host}" 2>&1 | tee -a $PROGRAM_LOG
        rvalue=${PIPESTATUS[0]}
        if [ $rvalue == 0 ]; then
            echo_log "Creating sudoers file ..."
            ssh "${user}@${host}" "sudo -S -- sh -c \"\
                    echo 'vcap ALL= NOPASSWD: /bin/touch,/bin/chmod,/bin/chown,/bin/rm,/bin/cp,/usr/bin/rsync,/usr/bin/sv,/var/vcap/bosh/bin/monit'> /etc/sudoers.d/backup && \
                    chmod 0440 /etc/sudoers.d/backup\"" 2>&1 | tee -a $PROGRAM_LOG
            echo_log "Testing connection: "
            exec_host "${user}" "${host}" "$MONIT summary" | tee -a $PROGRAM_LOG
            rvalue=${PIPESTATUS[0]}
        else
            error_log "failed to copy key"
        fi
    else
        error_log "failed to create cache dir"
    fi
    return $rvalue
}


# Main Program
# Parse the input
OPTIND=1
while getopts "hdc:-:" optchar; do
    case "${optchar}" in
        -)
            # long options
            case "${OPTARG}" in
                help)
                    usage
                    exit 0
                ;;
                debug)
                    DEBUG=1
                ;;
                config)
                  eval PROGRAM_CONF="\$${OPTIND}"
                  OPTIND=$(($OPTIND + 1))
                  [ ! -f "$PROGRAM_CONF" ] && die "Configuration file not found!"
                  . $PROGRAM_CONF && debug_log "($$): CONF=$PROGRAM_CONF"
                ;;
                *)
                    die "Unknown arg: ${OPTARG}"
                ;;
            esac
        ;;
        h)
            usage
            exit 0
        ;;
        d)
            DEBUG=1
        ;;
        c)
            PROGRAM_CONF=$OPTARG
            [ ! -f "$PROGRAM_CONF" ] && die "Configuration file not found!"
            . $PROGRAM_CONF && debug_log "($$): CONF=$PROGRAM_CONF"
        ;;
    esac
done
shift $((OPTIND-1)) # Shift off the options and optional --.
# Parse the rest of the options
[ ! -z "${SSH_PRIVATE_KEY}" ] && SSH="$SSH -i ${SSH_PRIVATE_KEY}"
RC=1
while [ $# -gt 0 ]; do
    case "$1" in
        backup)
            backup "${USER}" "${HOST}" "${DBS}" "${CACHE}" "RSYNC_LIST" "${OUTPUT}" "ADD_LIST"
            RC=$?
        ;;
        setup)
            setup "${USER}" "${HOST}" "${CACHE}" "${SSH_PUBLIC_KEY}"
            RC=$?
        ;;
        *)
            usage
            die "Unknown arg: ${1}"
        ;;
    esac
    shift
done

exit $RC

# EOF
