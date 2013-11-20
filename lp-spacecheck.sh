#!/bin/bash
. lp-backup.cfg

function SPACECHECK() {
DELTRIES=0
FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)

if [ "$FREEP" -gt 90 ]; then
	echo "There is enough room for a backup run.";
	#Do backup run function here.
else
	#this where the space clean up logic comes in to play
	#Do cleanup.
	#Get oldest backup dir based on $DIR and ctime on the directories and nuke it.
	if [ "$FREEP" -lt 90 ] && [ "$DELTRIES" -le 2 ]; then
		while [ "$FREEP" -lt 90 ] && [ "$DELTRIES" -le 2 ]; do
			DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
			echo "rm -rf $DELDIR"
			if [ "$FREEP" -gt 90 ]; then
				#call backup function here
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
SPACECHECK