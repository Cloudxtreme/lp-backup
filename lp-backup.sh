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
	#Clean out the old backup logs to prevent build up - shouldn't need more than 7 days worth.
	for i in $(find $LOGDIR -maxdepth 1 -type f -ctime +7 -iname backup-\*); do 
		BASE=$(basename $i)
		echo "$(LOGSTAMP) Removing old logfile: $BASE" >> $LOG; 
		/bin/rm -f $i || ; 
	done
}

function DRIVEMOUNT(){
	#Check if drive mounted; mount drive; fail out/notify if unable.
	#This will fail on the first attempt if the drive can't mount but isn't mounted already.
	CHECKMOUNT=$(/bin/mount | grep "$DRIVE")
	if [ -z "$CHECKMOUNT" ]; then
		/bin/mount $DRIVE $DIR >> $LOG 2>&1
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
	#Get free space percentage; clear room if needed (7 attempts) then fail out/notify
	#or start backup run.
	FREEP=$(/bin/df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "$(LOGSTAMP) Free space percentage: $FREEP. Thresh is: $FREETHRESH. \
		Deletion attempts: $DELTRIES" >> $LOG
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 7 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "$(LOGSTAMP) Cannot find valid target for removal, exiting." >> $LOG
			UNMOUNT
			FAILED
		else
			echo "$(LOGSTAMP) Removing: $DIR/$DELDIR" >> $LOG
			/bin/rm -rf $DIR/$DELDIR >> $LOG || { echo "$(LOGSTAMP) Failed removing $DIR/DELDIR - possible read-only FS?" >> $LOG; UNMOUNT; FAILED; }
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	else
		if [ $DELTRIES -gt 7 ] && [ "$FREEP" -ge "$FREETHRESH" ] ; then
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
	/bin/chmod 700 $BACKUPDIR
	echo "$(LOGSTAMP) Backing up to $BACKUPDIR." >> $LOG.
	#Begin looping the target array
	for i in "${TARGET[@]}"; do
		#Symlink check - don't need to recurse through these.
		if [ -L $i ]; then
			echo "$(LOGSTAMP) Target $i is a symlink, skipping to prevent unncessary recursion." >> $LOG
		else
			if [ -d "$i" ]; then
				#Create backup target now, then check for $COMPDIR and hardlink as necessary.
				/bin/mkdir -p $BACKUPDIR/$i
				if [ ! -z $COMPDIR ]; then
					#Populate the backup target using hardlinks from $COMPDIR
					echo "$(LOGSTAMP) Backing up: $i using hardlinks from $COMPDIR." >> $LOG;
					/usr/bin/rsync -a --delete --exclude-from="$SPATH/exclude.txt" --link-dest="$DIR/$COMPDIR/$i" $i/ $BACKUPDIR/$i/ >> $LOG 2>&1
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
					#Populate the backup target with unhardlinked data, as $COMPDIR is an empty string.
					echo "$(LOGSTAMP) Backing up: $i" >> $LOG;
					/usr/bin/rsync -a --exclude-from "$SPATH/exclude.txt" $i/ $BACKUPDIR/$i/ >> $LOG 2>&1
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
				fi
			else
				echo "$(LOGSTAMP) Backup target $i does not exist; skipping." >> $LOG
			fi
		fi
	done
	if $(/bin/ls /var/cpanel/users/ > /dev/null 2>&1); then
		echo "$(LOGSTAMP) cPanel users detected. Backing up homedirs." >> $LOG
		for i in `/bin/ls /var/cpanel/users`; do
			#Validate cPanel user homedirs against /etc/passwd. This isn't strictly necessary as symlinks should be there
			#but would rather be thorough.
			VALIDUSER=$(cut -f1 -d: /etc/passwd | /bin/grep -x $i)
			USERDIR=$(grep $i /etc/passwd | cut -f6 -d:)
			#Strict check to prevent partial username matching.
			if [ "$i" == "$VALIDUSER" ]; then
				#Valid user confirmed, look for the compdir for hardlinks (similar to above).
				if [ ! -z $COMPDIR ]; then
					if [ -d "$USERDIR" ]; then
						#Hardlinked home dir backups here.
						echo "$(LOGSTAMP) Backing up cPanel user: $i using hardlinks from $COMPDIR." >> $LOG;
						mkdir -p $BACKUPDIR/home/$i
						/usr/bin/rsync -a --delete --exclude-from="$SPATH/exclude.txt" --link-dest="$DIR/$COMPDIR/home" $USERDIR $BACKUPDIR/home >> $LOG 2>&1
						CHECK="$?"
						case "$CHECK" in
							0	)	
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
							23	)
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 23, may be incomplete data)." >> $LOG ;;
							24	)	
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
							*	)	
								echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting. (exited $CHECK)" >> $LOG
								UNMOUNT
								FAILED ;;
						esac
						#Shorthanded this. Don't modify the command string, as running it like this will be cPanel version agnostic.
						#Other formats will cause syntax errors.
						/scripts/pkgacct --skiphomedir $i $BACKUPDIR/home --skipacctdb > /dev/null 2>&1 || { echo "$(LOGSTAMP) Failed packaging cPanel user: $i." >> $LOG; UNMOUNT; FAILED; };
					else
						echo "$(LOGSTAMP) Home directory for user $i not found; skipping." >> $LOG
					fi
				else
					#Homedir backups without hardlinks.
					if [ ! -z $COMPDIR ]; then
						echo "$(LOGSTAMP) Backing up cPanel user: $i." >> $LOG
						mkdir -p $BACKUPDIR/home/$i
						/usr/bin/rsync -a --exclude-from "$SPATH/exclude.txt" $USERDIR $BACKUPDIR/home >> $LOG 2>&1 
						CHECK="$?"
						case "$CHECK" in
							0	)	
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 0)." >> $LOG ;;
							23	)
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 23, may be incomplete data)." >> $LOG ;;
							24	)	
								echo "$(LOGSTAMP) Backed up $i to $BACKUPDIR (exited 24)." >> $LOG ;;
							*	)	
								echo "$(LOGSTAMP) rsync error detected backing up $i. Exiting. (exited $CHECK)" >> $LOG
								UNMOUNT
								FAILED ;;
						esac
						#Shorthanded this. Don't modify the command string, as running it like this will be cPanel version agnostic.
						#Other formats will cause syntax errors.
						/scripts/pkgacct --skiphomedir $i $BACKUPDIR/home/$i --skipacctdb > /dev/null 2>&1 || { echo "$(LOGSTAMP) Failed packaging cPanel user: $i." >> $LOG; UNMOUNT; FAILED; };
					else
						echo "$(LOGSTAMP) Home directory for user $i not found; skipping." >> $LOG
					fi
				fi	
			else
				echo "$(LOGSTAMP) Cannot retrieve homedir for user $i. Ignoring." >> $LOG
			fi
		done
	else
		echo "$(LOGSTAMP) No cPanel user accounts detected. Skipping homedir backup." >> $LOG
	fi
	#SQL dumps begin here. Might be better to break this into a separate function in the future, and figure out 
	#a way to error check dumps a bit better. 
	#This block will not cause the script to halt on error as there are numerous cases of invalid DB names, etc.
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
	#Mount output will not have time stamps in order to support the older versions of BASH, sadly.
	umount $DIR >> $LOG 2>&1
	CHECKMOUNT=$(mount | grep "$DRIVE")
	if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -lt 9 ]; then
		echo "$(LOGSTAMP) $DRIVE failed to unmount properly, waiting two minutes and trying again." >> $LOG
		let UMOUNTS=$UMOUNTS+1
		echo "$(LOGSTAMP) Unmount attempts: $UMOUNTS" >> $LOG
		sleep 120
		UNMOUNT
	else
		if [ ! -z "$CHECKMOUNT" ] && [ "$UMOUNTS" -eq 9 ]; then
			echo "$(LOGSTAMP) $DRIVE failed to unmount after three attempts; exiting." >> $LOG
			FAILED
		fi
	fi
	if [ -z "$CHECKMOUNT" ]; then
		echo "$(LOGSTAMP) $DRIVE unmounted successfully." >> $LOG
	fi
}

function SUMMARY(){
	#While drive is still mounted, generate list of XML entries for the backup summary that Sonar checks
	#Hardcoded allowed variance as I'm not really sure how that plays in, but appears to be static across boxes.
	echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $SUMMARY
	echo " "  >> $SUMMARY
	echo "<backupSummary>" >> $SUMMARY
	echo "<backupDirectory>$DIR</backupDirectory>" >> $SUMMARY
	echo "<backupDevice>$DRIVE</backupDevice>" >> $SUMMARY
	echo "<diskUsageLimit>$(echo 99 - $FREETHRESH | bc)</diskUsageLimit>" >> $SUMMARY
	echo "<diskUsageLimitType>percentFree</diskUsageLimitType>" >> $SUMMARY
	echo "<allowedVariance>10</allowedVariance>" >> $SUMMARY
	echo "<diskSize>$(df -h /backup/ | tail -1 | awk '{ print $2 }' | sed 's/[A-Z]//g')</diskSize>" >> $SUMMARY
	echo "<gigsFree>$(df -h /backup/ | tail -1 | awk '{ print $4 }' | sed 's/[A-Z]//g')</gigsFree>" >> $SUMMARY
	echo "<percentFree>$(echo 100 - $(df -h /backup/ | tail -1 | awk '{ print $5 }'| sed 's/%//g') | bc)</percentFree>" >> $SUMMARY
	for i in $(ls $DIR | grep _backup); do echo \<backup date=\"$(echo $i | cut -f3 -d_ | sed 's/-/\//g')\" time=\"$(echo $i | cut -f4 -d_)\" \/\> >> $SUMMARY;  done
	echo '</backupSummary>' >> $SUMMARY
	echo "$(LOGSTAMP) Created summary file at $SUMMARY." >> $LOG
}


function FAILED(){
	#Function to be called during the cleanup process. Will need to be called at the end of unmounting
	#with error, and AFTER the unmount function in any irregular exit to prevent looping.
	echo "$(LOGSTAMP) Backup error detected, sending notification to $EMAIL." >> $LOG
	cat $LOG | mail -s "[lp-backup] Backup error on $HOSTNAME" "$EMAIL"
	exit 1

}

function NOTIFY(){
	#Will send log output if $NOTIFY=1 - all else will result in no notifications.
	if [ "$NOTIFY" -eq "1" ]; then
		echo "$(LOGSTAMP) General notifications enabled, sending report." >> $LOG
		cat $LOG | mail -s "[lp-backup] Backup report for $HOSTNAME" "$EMAIL"
	else
		echo "$(LOGSTAMP) Notifications disabled; backup complete." >> $LOG
	fi
}

#Call the functions to do the things.
#Log writing occurs outside of the function to prevent unnecessary repitition 
LOGINIT
echo "$(LOGSTAMP) Beginning drive mount:" >> $LOG
DRIVEMOUNT
echo "$(LOGSTAMP) Beginning space check:" >> $LOG
SPACECHECK
echo "$(LOGSTAMP) Beginning backups:" >> $LOG
BACKUP
echo "$(LOGSTAMP) Creating backup summary file:" >> $LOG
SUMMARY
echo "$(LOGSTAMP) Beginning unmount:" >> $LOG
UNMOUNT
NOTIFY