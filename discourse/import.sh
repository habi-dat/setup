#!/bin/bash
set +x

echo "Copying backup file to discourse container..."

docker exec $HABIDAT_DOCKER_PREFIX-discourse mkdir -p /shared/backups/default

docker cp $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse/$1 $HABIDAT_DOCKER_PREFIX-discourse:/shared/backups/default

echo "Enabling restore mode..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse enable_restore"

echo "Restoring..."

../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "discourse restore $1" > import.log

envsubst < config/discourse-settings-update.yml > ../store/discourse/bootstrap/discourse-settings.yml
../store/discourse/launcher run $HABIDAT_DOCKER_PREFIX-discourse "rake site_settings:import < /bootstrap/discourse-settings.yml"

if grep -q "\[SUCCESS\]" import.log 
then
	rm import.log
	echo "Finished, imported: $1"
else
	cat import.log
	rm import.log
	echo "Import failed, please check above logs"
	exit 0
fi