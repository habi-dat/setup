#!/bin/bash
set +x

echo "Copying backup file to discourse container..."

docker cp $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse/$1 $HABIDAT_DOCKER_PREFIX-discourse:/shared/backups/default

echo "Enabling restore mode..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse enable_restore"

echo "Restoring..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse restore $1" > import.log

if grep -q "\[SUCCESS\]" import.log 
	rm import.log
	echo "Finished, imported: $1"
else
	cat import.log
	rm import.log
	echo "Import failed, please check above logs"
	exit 0
fi