#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

if [ -z "$1" ]
then
	echo "Exporting nextcloud with user data (use option 'nodata' for excluding user data)..."
elif [ "$1" == "nodata" ]
then
	echo "Exporting nextcloud without user data"
else
	echo "Invalid option, available options: nodata"
	exit 0
fi 

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud

source ../store/nextcloud/passwords.env

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec db bash -c "mysqldump nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD > /backup.sql"
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-nextcloud-db":/backup.sql $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/db.sql

echo "Compressing data..."
datapath=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-nextcloud_data`
if [ -z "$1" ]
then
  tar -czf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/nextcloud-$DATE.tar.gz -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud db.sql -C "$datapath" data
else 
  appdata_dir=$(basename $(ls -d $datapath/data/appdata_*))
  tar -czf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/nextcloud-$DATE.tar.gz -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud db.sql -C "$datapath" data/$appdata_dir/theming -C "$datapath" data/$appdata_dir/external
fi
rm $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/db.sql

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/nextcloud-$DATE.tar.gz"
