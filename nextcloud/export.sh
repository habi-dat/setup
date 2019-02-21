#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting nextcloud database..."

mkdir -p ../store/export/nextcloud

source ../store/nextcloud/passwords.env

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec db bash -c "mysqldump nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD > /backup.sql"
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-nextcloud-db":/backup.sql ../store/export/nextcloud/export-$DATE.sql

echo "Compressing data..."
datapath=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-nextcloud_data`
tar -czf ../store/export/nextcloud/nextcloud-$DATE.tar.gz -C ../store/export/nextcloud/ export-$DATE.sql -C "$datapath" data
rm ../store/export/nextcloud/export-$DATE.sql

echo "Finished, filename: export/nextcloud/nextcloud-$DATE.tar.gz"
