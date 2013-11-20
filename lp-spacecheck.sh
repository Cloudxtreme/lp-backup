#!/bin/bash
. lp-backup.cfg

DELTRIES="0"
function SPACECHECK(){
	echo "$TS (in SPACECHECK()"
	FREEP=$(df -h $DRIVE | awk '{ print $5 }' | sed 's/%//' | tail -1)
	echo "Starting free space percentage: $FREEP"
	if [ "$FREEP" -ge "$FREETHRESH" ] && [ "$DELTRIES" -le 2 ]; then
		DELDIR=$(/bin/ls -1c $DIR | grep _backup | tail -1)
		if [ -z "$DELDIR" ]; then
			echo "Cannot find valid target for removal or deletion tries exceeded."
		else
			echo "Removing: $DIR/$DELDIR"
			echo "/bin/rm -r $DIR/$DELDIR"
			let DELTRIES=$DELTRIES+1
			SPACECHECK
		fi
	fi
	echo "Space is adequate, continuing backup."
}
SPACECHECK