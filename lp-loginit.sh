#!/bin/bash
. lp-backup.cfg

function LOGINIT() {
	declare -r TS=`date +%m-%d-%Y_%R`
	if [ ! -f "$LOGDIR" ]; then
		mkdir -p $LOGDIR
		touch $LOGDIR/backup-$TS.log
	else
		touch $LOGDIR/backup-$TS.log
	fi
}
LOGINIT
