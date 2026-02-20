#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env
source ../store/discourse/passwords.env

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

echo "Generating API key and update user service..."

unset HABIDAT_DISCOURSE_API_KEY
export HABIDAT_DISCOURSE_API_KEY=$(echo $(docker exec $HABIDAT_DOCKER_PREFIX-discourse rake api_key:create_master[usertool]) | tr -d "\r" | awk '{print $NF}')
while [ -z "$HABIDAT_DISCOURSE_API_KEY" ]
do
	sleep .5
done
echo "export HABIDAT_DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/discourse/passwords.env

# remove API vars from auth module env
touch ../store/auth/auth.env
sed -i '/DISCOURSE_API_KEY=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_URL=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_API_USERNAME=/d' ../store/auth/auth.env

# rewrite API vars to auth module env
echo "DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/auth/auth.env
echo "DISCOURSE_URL=http://$HABIDAT_DOCKER_PREFIX-discourse:80" >> ../store/auth/auth.env
echo "DISCOURSE_API_USERNAME=system" >> ../store/auth/auth.env

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d 