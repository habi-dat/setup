#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting nextcloud database..."

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud

source ../store/nextcloud/passwords.env

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec db bash -c "mysqldump nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD > /backup.sql"
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-nextcloud-db":/backup.sql $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/db.sql

echo "Compressing data..."
datapath=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-nextcloud_data`
tar -czf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/nextcloud-$DATE.tar.gz -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud db.sql -C "$datapath" data
rm $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/db.sql

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/nextcloud-$DATE.tar.gz"
