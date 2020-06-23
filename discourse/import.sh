#!/bin/bash
set +x

echo "Copying backup file to discourse container..."

docker cp $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse/$1 $HABIDAT_DOCKER_PREFIX-discourse:/shared/backups/default

echo "Enabling restore mode..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse enable_restore"

echo "Restoring..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse restore $1" > import.log

SUCCESS=$(import.log | grep "[SUCCESS]")

if [ -z "$SUCCESS" ]; then
	cat import.log
	rm import.log
	echo "Import failed, please check above logs"
	exit 0
else
	echo "Finished, imported: $1"
fi