#!/bin/bash
. lp-backup.cfg

DELTRIES="1"
function SPACECHECK(){
	echo "$TS (in SPACECHECK()"
	FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "Starting free space percentage: $FREEP. Deletion attempts: $DELTRIES"
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -lt 3 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "Cannot find valid target for removal."
		else
			echo "Removing: $DIR/$DELDIR"
			echo "/bin/rm -r $DIR/$DELDIR"
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	else
		echo "Deletion attempts exceed, exiting."
		exit 1
	fi
	echo "Space is adequate, continuing backup."
}
SPACECHECK