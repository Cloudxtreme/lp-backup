#!/bin/bash
set -e
set -u
. lp-backup.cfg

function DRIVEMOUNT(){
CHECKMOUNT=$(mount | grep "$DRIVE")

if [ -z "$CHECKMOUNT" ]; then
	mount $DRIVE $DIR
 	CHECKMOUNT=$(mount | grep "$DRIVE")
 	if [ -z "$CHECKMOUNT" ]; then
 		echo "Could not mount $DRIVE to $DIR."
 		exit 1;
 		#Add logging here.
 	else
 		echo "Mounted $DRIVE to $DIR." #MFD
 		#Add logging here.
 	fi
 else
 	echo "$DRIVE already mounted."
 fi
}

function SPACECHECK() {
DELTRIES=0
FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)

if [ "$FREEP" -lt "$FREETHRESH" ]; then
	echo "There is enough room for a backup run.";
	#Do backup run function here.
else
	#this where the space clean up logic comes in to play
	#Do cleanup.
	#Get oldest backup dir based on $DIR and ctime on the directories and nuke it.
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; then
		while [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; do
			DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
			echo "rm -rf $DIR/$DELDIR"
			/bin/rm -r $DIR/$DELDIR
			if [ "$FREEP" -lt "$FREETHRESH" ]; then
				#call backup function here
				BACKUP
				echo "If statement backup run."
				#break the while loop since the backup can be started.
				DELTRIES=3
			else
				if [ "$DELTRIES" -ge 2 ]; then
					echo "Can't free space to run backup."
					exit 1
				else
					let DELTRIES=$DELTRIES+1
				fi
			fi
		done
	fi
fi
}

function BACKUP() {
	#Make the backup directory with the timestamp, declare $TS as readonly so we don't lose
	#the backup target mid-run.
	declare -r TS=`date +%m-%d-%Y_%R`
	echo $TS #MFD
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
			/usr/local/cpanel/scripts/pkgacct $i $BACKUPDIR/$i/ --skiphomedir --skipacctdb;
		done
	else
		echo "No cPanel user accounts detected. Skipping homedir backup."
	fi
	exit 0
}
DRIVEMOUNT
SPACECHECK
BACKUP