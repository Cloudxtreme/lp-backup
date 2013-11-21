#!/bin/bash
#set -e
set -u
. lp-backup.cfg

function LOGSTAMP(){
	#General purpose log time stamping to be used with standard echos,
	#
	echo "[$(date +%m-%d-%Y\ %T)]"
}

function LOGINIT() {
	#declare -r TS=`date +%m-%d-%Y_%R`
	if [ ! -f "$LOGDIR" ]; then
		mkdir -p $LOGDIR
		touch $LOG
	else
		touch $LOG
	fi
	#Log cleanup stuff will need to go here. 
}

function DRIVEMOUNT(){
CHECKMOUNT=$(mount | grep "$DRIVE")
if [ -z "$CHECKMOUNT" ]; then
	mount $DRIVE $DIR 2>&1 > $LOG
 	CHECKMOUNT=$(mount | grep "$DRIVE")
 	if [ -z "$CHECKMOUNT" ]; then
 		echo "$(LOGSTAMP) Could not mount $DRIVE to $DIR; exiting." >> $LOG
 		#Alert.
 		exit 1;
 		#Add logging here.a
 	else
 		echo "$LOGSTAMP Mounted $DRIVE to $DIR." #MFD
 		#Add logging here.
 	fi
 else
 	echo "$(LOGSTAMP) $DRIVE already mounted."
 fi
}

function SPACECHECK(){
	FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "$(LOGSTAMP) Free space percentage: $FREEP. Thresh is: $FREETHRESH. \
		Deletion attempts: $DELTRIES" >> $LOG
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "$(LOGSTAMP) Cannot find valid target for removal, exiting." >> $LOG
			#Need cleanup here.
			exit 1
		else
			echo "$(LOGSTAMP) Removing: $DIR/$DELDIR" >> $LOG
			/bin/rm -r $DIR/$DELDIR
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	else
		if [ $DELTRIES -gt 2 ] && [ "$FREEP" -ge "$FREETHRESH" ] ; then
			echo "$(LOGSTAMP) Deletion attempts exceed, exiting." >> $LOG
			#Need cleanup here.
			exit 1
		fi
	fi
}

function BACKUP() {
	#Make the backup directory with the timestamp, declare $TS as readonly so we don't lose
	#the backup target mid-run.
	#declare -r TS=`date +%m-%d-%Y_%R`
	BACKUPDIR="$DIR/_backup_$TS"
	/bin/mkdir -p $BACKUPDIR
	#Loop through the defined targets array before moving on to homedirs.
	for i in "${TARGET[@]}"; do
		echo "$(LOGSTAMP) Backing up: $i" >> $LOG;
		/usr/bin/rsync -aH --exclude-from 'exclude.txt' $i $BACKUPDIR/
	done
	#Get the cPanel users' homedires and back them up to the destination.
	if $(/bin/ls /var/cpanel/users/ > /dev/null 2>&1); then
		echo "$(LOGSTAMP) cPanel users detected. Backing up homedirs." >> $LOG
		for i in `/bin/ls /var/cpanel/users`; do
			VALIDUSER=$(grep $i /etc/passwd | cut -f1 -d:)
			if [ "$i" == "$VALIDUSER" ]; then
				echo "$(LOGSTAMP) Backing up cPanel user: $i" >> $LOG;
				/usr/bin/rsync -aH $(grep $i /etc/passwd | cut -f6 -d:) $BACKUPDIR; 
				#Failout if pkgacct fails - need to add a call to UNMOUNT here for cleanup purposes.
				/usr/local/cpanel/scripts/pkgacct $i $BACKUPDIR/$i --skiphomedir --skipacctdb > /dev/null 2>&1 \
				|| { echo "$LOGSTAMP Failed packaging cPanel user: $i." >> $LOG; exit 1; };
			else
				echo "$(LOGSTAMP) Cannot retrieve homedir for user $i. Ignoring." >> $LOG
			fi
		done
	else
		echo "$(LOGSTAMP) No cPanel user accounts detected. Skipping homedir backup." >> $LOG
	fi

	#exit 0
}

function UNMOUNT(){
	umount $DIR >> $LOG 2>&1 >> $LOG
	CHECKMOUNT=$(mount | grep "$DRIVE")
	if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -lt 2 ]; then
		echo "$(LOGSTAMP) $DRIVE failed to unmount properly, waiting 60 and trying again." >> $LOG
		let UMOUNTS=$UMOUNTS+1
		echo "$(LOGSTAMP) Unmount attempts: $UMOUNTS" >> $LOG
		sleep 2
		UNMOUNT
	else
		if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -eq 2 ]; then
			echo "$(LOGSTAMP) $DRIVE failed to unmount after three attempts; exiting." >> $LOG
			exit 1
		fi
	fi
	if [ -z "$CHECKMOUNT" ]; then
		echo "$(LOGSTAMP) $DRIVE unmounted successfully." >> $LOG
	fi
}
echo "$(LOGSTAMP) Beginning backup run." >> $LOG
echo "$(LOGSTAMP) Beginning log clean up/initialization:" >> $LOG
#LOGINIT
echo "$(LOGSTAMP) Beginning drive mount:" >> $LOG
#DRIVEMOUNT
echo "$(LOGSTAMP) Beginning space check:" >> $LOG
#SPACECHECK
echo "$(LOGSTAMP) Beginning backups:" >> $LOG
#BACKUP
echo "$(LOGSTAMP) Beginning unmount:" >> $LOG
#UNMOUNT