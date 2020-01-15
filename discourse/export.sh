#!/bin/bash
set +x

echo "Generating discourse backup file..."

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse

filename=$(docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bash -c "bundle exec ruby /opt/bitnami/discourse/script/discourse backup" | sed -n 's#Output file is in: /opt/bitnami/discourse/public/backups/\([0-9a-z./-]*\)#\1#p')
if [ -z $filename ]
then
	echo "Backup file could not be generated, please check discourse logs! Aborting export..."
	exit 1
fi

# remove control characters (this is somehow necessary...)
filename="${filename%%[[:cntrl:]]}"

DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-discourse:/bitnami/discourse/public/backups/$filename" $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse/discourse-$DATE.tar.gz

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/discourse/discourse-$DATE.tar.gz"
exit 0
