#!/bin/bash
set +x



#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Stopping nextcloud..."

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" stop nextcloud cron

datapath=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-nextcloud_data`

echo "Deleting existing data..."

appdata_dir=$(basename $(ls -d $datapath/data/appdata_*))

rm -rf "$datapath/data"

echo "Extracting data..."

tar -xzf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/$1 -C $datapath

appdata_dir_import=$(basename $(ls -d $datapath/data/appdata_*))
mv $datapath/data/$appdata_dir_import $datapath/data/$appdata_dir

chown -R www-data:www-data $datapath/data

echo "Restoring database dump..."

source ../store/nextcloud/passwords.env

cat "$datapath/db.sql" | docker exec -i $HABIDAT_DOCKER_PREFIX-nextcloud-db mysql nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD
rm "$datapath/db.sql";

echo "Updating nextcloud..."
./update.sh

echo "Finished, imported: $1"
