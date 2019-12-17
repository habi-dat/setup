#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting direktkredit database..."

DATE=$(date +"%Y%m%d%H%M")

mkdir -p ../store/export/direktkredit/export-$DATE

source ../store/direktkredit/passwords.env

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" exec db bash -c "mysqldump $HABIDAT_DOCKER_PREFIX -u root --password=$HABIDAT_DK_DB_ROOT_PASSWORD > /backup.sql"
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-direktkredit-db":/backup.sql ../store/export/direktkredit/export-$DATE/export-$DATE.sql

echo "Compressing data..."
datapath_files=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_files`
datapath_images=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_images`
datapath_upload=`docker volume inspect -f "{{.Mountpoint}}" $HABIDAT_DOCKER_PREFIX-direktkredit_upload`

cp -rp $datapath_files ../store/export/direktkredit/export-$DATE/files
cp -rp $datapath_images ../store/export/direktkredit/export-$DATE/images
cp -rp $datapath_upload ../store/export/direktkredit/export-$DATE/upload
tar -czf ../store/export/direktkredit/direktkredit-$DATE.tar.gz -C ../store/export/direktkredit/export-$DATE export-$DATE.sql files images upload
rm -r ../store/export/direktkredit/export-$DATE

echo "Finished, filename: export/direktkredit/direktkredit-$DATE.tar.gz"
