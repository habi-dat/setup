#!/bin/bash
set +x

echo "Creating discourse backup file (this may take a while)..."

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse backup" > export.log

SUCCESS=$(export.log | grep "[SUCCESS]")

if [ -z "$SUCCESS" ]; then
	cat export.log
	rm export.log
	echo "Creating backup file failed, please check above logs"
	exit 0
else
	rm export.log
	BACKUP_FILENAME=$(docker exec $HABIDAT_DOCKER_PREFIX-discourse ls -Art /shared/backups/default | tail -n 1)	

	echo "Creating backup file succeeded, copying $BACKUP_FILENAME to $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse ..."
	docker cp $HABIDAT_DOCKER_PREFIX-discourse:/shared/backups/default/$BACKUP_FILENAME $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse

	echo "Finished, filename: $BACKUP_FILENAME"

fi