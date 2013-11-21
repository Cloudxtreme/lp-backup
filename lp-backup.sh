#!/bin/bash
#set -e
set -u
. lp-backup.cfg


function LOGINIT() {
	#declare -r TS=`date +%m-%d-%Y_%R`
	if [ ! -f "$LOGDIR" ]; then
		mkdir -p $LOGDIR
		touch $LOG
	else
		touch $LOG
	fi
	/bin/date >> $LOG
	echo "Beginning backup run."

}

function DRIVEMOUNT(){
CHECKMOUNT=$(mount | grep "$DRIVE")
if [ -z "$CHECKMOUNT" ]; then
	mount $DRIVE $DIR 2&> /dev/null
 	CHECKMOUNT=$(mount | grep "$DRIVE")
 	if [ -z "$CHECKMOUNT" ]; then
 		echo "Could not mount $DRIVE to $DIR." >> $LOG
 		exit 1;
 		#Add logging here.a
 	else
 		echo "Mounted $DRIVE to $DIR." #MFD
 		#Add logging here.
 	fi
 else
 	echo "$DRIVE already mounted."
 fi
}

function SPACECHECK(){
	echo "$TS (in SPACECHECK()"
	FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "Starting free space percentage: $FREEP. Thresh is: $FREETHRESH. Deletion attempts: $DELTRIES"
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "Cannot find valid target for removal, exiting."
			exit 1
		else
			echo "Removing: $DIR/$DELDIR"
			/bin/rm -r $DIR/$DELDIR
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	else
		if [ $DELTRIES -gt 2 ] && [ "$FREEP" -ge "$FREETHRESH" ] ; then
			echo "Deletion attempts exceed, exiting."
			exit 1
		fi
	fi
	echo "Space is adequate, continuing backup."
}

function BACKUP() {
	#Make the backup directory with the timestamp, declare $TS as readonly so we don't lose
	#the backup target mid-run.
	#declare -r TS=`date +%m-%d-%Y_%R`
	echo "$TS (in Backup)" #MFD
	BACKUPDIR="$DIR/_backup_$TS"
	/bin/mkdir -p $BACKUPDIR
	#Loop through the defined targets array before moving on to homedirs.
	for i in "${TARGET[@]}"; do
		echo Backing up: $i;
		/usr/bin/rsync -aH --exclude-from 'exclude.txt' $i $BACKUPDIR/
	done
	#Get the cPanel users' homedires and back them up to the destination.
	if $(/bin/ls /var/cpanel/users/ > /dev/null 2>&1); then
		echo "cPanel users detected. Backing up homedirs."
		for i in `/bin/ls /var/cpanel/users`; do 
			echo "Backing up cPanel user: $i";
			/usr/bin/rsync -aH $(grep $i /etc/passwd | cut -f6 -d:) $BACKUPDIR; 
			/usr/local/cpanel/scripts/pkgacct $i $BACKUPDIR/$i --skiphomedir --skipacctdb || \
				{ echo "Failed packaging cPanel user: $i."; exit 1; };
		done
	else
		echo "No cPanel user accounts detected. Skipping homedir backup."
	fi

	exit 0
}

function UNMOUNT(){
	umount $DIR >> $LOG 2>&1
	CHECKMOUNT=$(mount | grep "$DRIVE")
	if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -lt 2 ]; then
		echo "$DRIVE failed to unmount properly, waiting 60 and trying again."
		let UMOUNTS=$UMOUNTS+1
		echo "Unmount attempts: $UMOUNTS"
		sleep 2
		UNMOUNT
	else
		if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -eq 2 ]; then
			echo "$DRIVE failed to unmount after three attempts; exiting."
			exit 1
		fi
	fi
	if [ -z "$CHECKMOUNT" ]; then
		echo "$DRIVE unmounted successfully."
	fi
}
echo "$LOGSTAMP Beginning backup run."
echo "$LOGSTAMP Beginning log clean up/initialization:"
#LOGINIT
echo "$LOGSTAMP Beginning drive mount:"
DRIVEMOUNT
echo "$LOGSTAMP Beginning space check:"
SPACECHECK
echo "$LOSTAMP Beginning backups:"
BACKUP
echo "$LOGSTAMP Beginning unmount:"
UNMOUNT