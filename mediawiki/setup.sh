#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/mediawiki

echo "Generating passwords..."

export HABIDAT_MEDIAWIKI_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_MEDIAWIKI_DB_PASSWORD=$HABIDAT_MEDIAWIKI_DB_PASSWORD" > ../store/mediawiki/passwords.env
echo "export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD=$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" >> ../store/mediawiki/passwords.env

envsubst < config/db.env > ../store/mediawiki/db.env
envsubst < config/web.env > ../store/mediawiki/web.env

envsubst < docker-compose.yml > ../store/mediawiki/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mediawiki/web.env
fi

echo "Spinning up containers..."

docker-compose -f ../store/mediawiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki" pull
docker-compose -f ../store/mediawiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki" build
docker-compose -f ../store/mediawiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki" up -d

echo "Waiting for mediawiki container to initialize (this can take several minutes)..."
# wait until discourse bootstrap is done
until [ -e $(docker volume inspect --format '{{ .Mountpoint }}' $HABIDAT_DOCKER_PREFIX-mediawiki_web)/CONTAINER_INITIALIZED ]
do
	sleep .5	
done

echo "Add project logo..."

if [ -f "../$HABIDAT_LOGO" ]
then
	docker cp "../$HABIDAT_LOGO" $HABIDAT_DOCKER_PREFIX-mediawiki:/var/www/html/images
fi
docker-compose -f ../store/mediawiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki" exec --user www-data web php maintenance/importImages.php images

# update nextcloud external sites
echo "Add link to nextcloud..."

sed -i '/HABIDAT_MEDIAWIKI_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_MEDIAWIKI_SUBDOMAIN=$HABIDAT_MEDIAWIKI_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-update-externalsites.sh