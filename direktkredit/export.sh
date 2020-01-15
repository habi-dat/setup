#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting direktkredit database..."

DATE=$(date +"%Y%m%d%H%M")

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE

source ../store/direktkredit/passwords.env

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" exec db bash -c "mysqldump $HABIDAT_DOCKER_PREFIX -u root --password=$HABIDAT_DK_DB_ROOT_PASSWORD > /backup.sql"
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-direktkredit-db":/backup.sql $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE/export-$DATE.sql

echo "Compressing data..."
datapath_files=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_files`
datapath_images=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_images`
datapath_upload=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_upload`

cp -rp $datapath_files $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE/files
cp -rp $datapath_images $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE/images
cp -rp $datapath_upload $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE/upload
tar -czf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/direktkredit-$DATE.tar.gz -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE export-$DATE.sql files images upload
rm -r $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/export-$DATE

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/direktkredit/direktkredit-$DATE.tar.gz"
