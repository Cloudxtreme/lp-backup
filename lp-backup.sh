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
		/bin/mkdir -p $LOGDIR
		/bin/touch $LOG
	else
		/bin/touch $LOG
	fi
	#Log cleanup stuff will need to go here. 
}

function DRIVEMOUNT(){
CHECKMOUNT=$(/bin/mount | grep "$DRIVE")
if [ -z "$CHECKMOUNT" ]; then
	/bin/mount $DRIVE $DIR >> $LOG 2>&1
 	CHECKMOUNT=$(/bin/mount | grep "$DRIVE")
 	if [ -z "$CHECKMOUNT" ]; then
 		echo "$(LOGSTAMP) Could not mount $DRIVE to $DIR; exiting." >> $LOG
 		#Alert.
 		FAILED
 		#Add logging here.a
 	else
 		echo "$LOGSTAMP Mounted $DRIVE to $DIR." #MFD
 		#Add logging here.
 	fi
 else
 	echo "$(LOGSTAMP) $DRIVE already mounted." >> $LOG
 fi
}

function SPACECHECK(){
	FREEP=$(/bin/df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "$(LOGSTAMP) Free space percentage: $FREEP. Thresh is: $FREETHRESH. \
		Deletion attempts: $DELTRIES" >> $LOG
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "$(LOGSTAMP) Cannot find valid target for removal, exiting." >> $LOG
			UNMOUNT
			FAILED
		else
			echo "$(LOGSTAMP) Removing: $DIR/$DELDIR" >> $LOG
			/bin/rm -r $DIR/$DELDIR
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	else
		if [ $DELTRIES -gt 2 ] && [ "$FREEP" -ge "$FREETHRESH" ] ; then
			echo "$(LOGSTAMP) Deletion attempts exceed, exiting." >> $LOG
			UNMOUNT
			FAILED
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
				|| { echo "$LOGSTAMP Failed packaging cPanel user: $i." >> $LOG; FAILED; };
			else
				echo "$(LOGSTAMP) Cannot retrieve homedir for user $i. Ignoring." >> $LOG
			fi
		done
	else
		echo "$(LOGSTAMP) No cPanel user accounts detected. Skipping homedir backup." >> $LOG
	fi
	#Here comes the SQL dumps.
	/bin/mkdir -p $BACKUPDIR/mysqldumps
	echo "$(LOGSTAMP) Beginning MySQL dumps." >> $LOG
	for i in $(mysql -e 'show databases;' | sed '/Database/d' | grep -v "information_schema"); do
		#Use the if return for notification, otherwise, dump errors to general log for review.
		/usr/bin/mysqldump --ignore-table=mysql.event $i > $BACKUPDIR/mysqldumps/$i.sql  2>> $LOG || { echo \ 
			"$LOGSTAMP Dumping $i returned error." >> $LOG; }
	done

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
			FAILED
		fi
	fi
	if [ -z "$CHECKMOUNT" ]; then
		echo "$(LOGSTAMP) $DRIVE unmounted successfully." >> $LOG
	fi
}

function FAILED(){
	#Function to be called during the cleanup process. Will need to be called at the end of unmounting
	#with error, and AFTER the unmount function in any irregular exit to prevent looping.
	echo "$(LOGSTAMP) Backup error detected, sending notification to $EMAIL." >> $(cat $LOG)
	mail -s "[lp-backup] Backup error on $HOSTNAME" "$EMAIL" << $LOG
	exit 1

}

function NOTIFY(){
	if [ "$NOTIFY" -eq "1" ]; then
		echo "$(LOGSTAMP) General notifications enabled, sending report."
		mail -s "[lp-backup] Backup report for $HOSTNAME" "$EMAIL" << $(cat $LOG)
	else
		Echo "$(LOGSTAMP) Notifications disabled; backup complete."
	fi
}

echo "$(LOGSTAMP) Beginning backup run." >> $LOG
echo "$(LOGSTAMP) Beginning log clean up/initialization:" >> $LOG
#LOGINIT
echo "$(LOGSTAMP) Beginning drive mount:" >> $LOG
DRIVEMOUNT
echo "$(LOGSTAMP) Beginning space check:" >> $LOG
SPACECHECK
echo "$(LOGSTAMP) Beginning backups:" >> $LOG
BACKUP
echo "$(LOGSTAMP) Beginning unmount:" >> $LOG
UNMOUNT
NOTIFY