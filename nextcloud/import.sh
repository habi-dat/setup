#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Stopping nextcloud..."

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" stop nextcloud cron

datapath=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-nextcloud_data`

echo "Deleting existing data..."

rm -rf "$datapath/data"

echo "Extracting data..."

tar -xzf -C "$datapath" $1 

echo "Restoring database dump..."

cat "$datapath/db.sql" | docker exec -i $HABIDAT_DOCKER_PREFIX-nextcloud-db mysql nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD
rm "$datapath/db.sql";

echo "Updating nextcloud..."
./update.sh

echo "Finished, imported: $1"
