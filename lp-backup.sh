#!/bin/bash
#lp-backup.sh

#Set to error out on unbound variables
#EVerything should be error checked while being passed to commands
#but added precaution to stop any errorneous rm/rsyncs.
set -u
SPATH="/usr/local/lp/apps/backup/lp-backup"
. $SPATH/lp-backup.cfg #Load configuration file.

function LOGSTAMP(){
	#General purpose log time stamping to be used with standard echos.
	echo "[$(date +%m-%d-%Y\ %T)]"
}

function LOGINIT() {
	#Check if the log directory exists; make it.
	#Create the logfile for our run.
	if [ ! -f "$LOGDIR" ]; then
		/bin/mkdir -p $LOGDIR
		/bin/touch $LOG
	else
		/bin/touch $LOG
	fi
	#Log cleanup stuff will need to go here.
	for i in $(find $LOGDIR -maxdepth 1 -type f -ctime +7 -iname backup-\*); do 
		BASE=$(basename $i)
		echo "$(LOGSTAMP) Removing old logfile: $BASE" >> $LOG; 
		/bin/rm -f $i; 
	done
}

function DRIVEMOUNT(){
	#Check if drive mounted; mount drive; fail out/notify if unable.
	#The giant printf block exists to time stamp mounting errors, to make troubleshooting easier, as these
	#will be the most common cause for erroring out.
	CHECKMOUNT=$(/bin/mount | grep "$DRIVE")
	if [ -z "$CHECKMOUNT" ]; then
		/bin/mount $DRIVE $DIR > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1
 		CHECKMOUNT=$(/bin/mount | grep "$DRIVE")
 	if [ -z "$CHECKMOUNT" ]; then
 		echo "$(LOGSTAMP) Could not mount $DRIVE to $DIR; exiting." >> $LOG
 		FAILED
 	else
 		echo "$(LOGSTAMP) Mounted $DRIVE to $DIR." >> $LOG
 	fi
 else
 	echo "$(LOGSTAMP) $DRIVE already mounted." >> $LOG
 fi
}

function SPACECHECK(){
	#Get free space percentage; clear room if needed (3 attempts) then fail out/notify
	#or start backup run.
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
	#Do the backup run
	#Create backup target, loop through TARGET array, rsync to target
	#Detect/loop through cPanel users, confirm home dir, rsync to target
	#Do MySQL dumps minus information_schema
	#Function will failout on cPanel/rsync errors but NOT MySQL errors.
	COMPDIR=$(/bin/ls -1c $DIR | grep _backup | head -1)
	BACKUPDIR="$DIR/_backup_$TS"
	/bin/mkdir -p $BACKUPDIR/home
	echo "$(LOGSTAMP) Backing up to $BACKUPDIR." >> $LOG
	#rsyncs begin here.
	for i in "${TARGET[@]}"; do
		if [ -L $i ]; then
			echo "$(LOGSTAMP) Target $i is a symlink, skipping to prevent unncessary recursion." >> $LOG
		else
			/bin/mkdir -p $BACKUPDIR/$i
			if [ -d "$i" ]; then
				if [ ! -z $COMPDIR ]; then
					echo "$(LOGSTAMP) Backing up: $i using hardlinks from $COMPDIR." >> $LOG;
					/usr/bin/rsync -a --delete --link-dest="$DIR/$COMPDIR/$i" --exclude-from="$SPATH/exclude.txt" $i/ $BACKUPDIR/$i/ > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1
					CHECK="$?"
					case "$CHECK" in
						0	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
						24	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
						*	)	
							echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting." >> $LOG
							UNMOUNT
							FAILED ;;
					esac
				else
					echo "$(LOGSTAMP) Backing up: $i" >> $LOG;
					/usr/bin/rsync -aH --exclude-from "$SPATH/exclude.txt" $i $BACKUPDIR/$i/ > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1
					case "$CHECK" in
						0	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
						24	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
						*	)	
							echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting." >> $LOG
							UNMOUNT
							FAILED ;;
					esac
				fi
			else
				echo "$(LOGSTAMP) Backup target $i does not exist; skipping." >> $LOG
			fi
		fi
	done
	if $(/bin/ls /var/cpanel/users/ > /dev/null 2>&1); then
		echo "$(LOGSTAMP) cPanel users detected. Backing up homedirs." >> $LOG
		for i in `/bin/ls /var/cpanel/users`; do
			VALIDUSER=$(grep $i /etc/passwd | cut -f1 -d:)
			if [ "$i" == "$VALIDUSER" ]; then
				if [ ! -z $COMPDIR ]; then
					echo "$(LOGSTAMP) Backing up cPanel user: $i using hardlinks from $COMPDIR." >> $LOG;
					mkdir -p $BACKUPDIR/home/$i
					/usr/bin/rsync -a --delete --link-dest="$DIR/$COMPDIR/home/$i" --exclude-from="$SPATH/exclude.txt" $(grep $i /etc/passwd | cut -f6 -d:) $BACKUPDIR/home > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1
					CHECK="$?"
					case "$CHECK" in
						0	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
						24	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
						*	)	
							echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting. (exited $CHECK)" >> $LOG
							UNMOUNT
							FAILED ;;
					esac
					/scripts/pkgacct --skiphomedir $i $BACKUPDIR/home/$i --skipacctdb > /dev/null 2>&1 || { echo "$(LOGSTAMP) Failed packaging cPanel user: $i." >> $LOG; UNMOUNT; FAILED; };
				else
					echo "$(LOGSTAMP) Backing up cPanel user: $i."
					/usr/bin/rsync -aH --exclude-from "$SPATH/exclude.txt" $(grep $i /etc/passwd | cut -f6 -d:) $BACKUPDIR/home/$i > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1 
					case "$CHECK" in
						0	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
						24	)	
							echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
						*	)	
							echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting. (exited $CHECK)" >> $LOG
							UNMOUNT
							FAILED ;;
					esac
					/scripts/pkgacct --skiphomedir $i $BACKUPDIR/home/$i --skipacctdb > /dev/null 2>&1 || { echo "$(LOGSTAMP) Failed packaging cPanel user: $i." >> $LOG; UNMOUNT; FAILED; };
				fi	
			else
				echo "$(LOGSTAMP) Cannot retrieve homedir for user $i. Ignoring." >> $LOG
			fi
		done
	else
		echo "$(LOGSTAMP) No cPanel user accounts detected. Skipping homedir backup." >> $LOG
	fi
	#SQL dumps begin here.
	/bin/mkdir -p $BACKUPDIR/mysqldumps
	echo "$(LOGSTAMP) Beginning MySQL dumps." >> $LOG
	for i in $(mysql -e 'show databases;' | sed '/Database/d' | grep -v "information_schema" | grep -v "performance_schema"); do
		/usr/bin/mysqldump --ignore-table=mysql.event $i > $BACKUPDIR/mysqldumps/$i.sql  2>> $LOG || { echo "$(LOGSTAMP) Dumping $i returned error." >> $LOG; }
	done
}

function UNMOUNT(){
	#Unmount the the backup drive.
	#Called by FAILED to execute cleanup prior to exit.
	#Will attempt to unmount the backup drive 3 times, then return as a failed backup.
	#Same printf as for mounting to aid troubleshooting.
	umount $DIR > >(while read -r line; do printf '%s %s\n' "[$(date +%m-%d-%Y\ %T)]" "$line"; done >> $LOG) 2>&1
	CHECKMOUNT=$(mount | grep "$DRIVE")
	if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -lt 2 ]; then
		echo "$(LOGSTAMP) $DRIVE failed to unmount properly, waiting 60 and trying again." >> $LOG
		let UMOUNTS=$UMOUNTS+1
		echo "$(LOGSTAMP) Unmount attempts: $UMOUNTS" >> $LOG
		sleep 60
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
	echo "$(LOGSTAMP) Backup error detected, sending notification to $EMAIL." >> $LOG
	cat $LOG | mail -s "[lp-backup] Backup error on $HOSTNAME" "$EMAIL"
	exit 1

}

function NOTIFY(){
	#Will send logout if $NOTIFY=1 - all else will result in no notifications.
	if [ "$NOTIFY" -eq "1" ]; then
		echo "$(LOGSTAMP) General notifications enabled, sending report." >> $LOG
		cat $LOG | mail -s "[lp-backup] Backup report for $HOSTNAME" "$EMAIL"
	else
		Echo "$(LOGSTAMP) Notifications disabled; backup complete." >> $LOG
	fi
}


LOGINIT
echo "$(LOGSTAMP) Beginning drive mount:" >> $LOG
DRIVEMOUNT
echo "$(LOGSTAMP) Beginning space check:" >> $LOG
SPACECHECK
echo "$(LOGSTAMP) Beginning backups:" >> $LOG
BACKUP
echo "$(LOGSTAMP) Beginning unmount:" >> $LOG
UNMOUNT
NOTIFY