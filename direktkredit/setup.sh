#!/bin/bash
set +x

source ../store/auth/passwords.env

mkdir -p ../store/direktkredit

export HABIDAT_DK_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_DK_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_DK_DB_PASSWORD=$HABIDAT_DK_DB_PASSWORD" > ../store/direktkredit/passwords.env
echo "export HABIDAT_DK_DB_ROOT_PASSWORD=$HABIDAT_DK_DB_ROOT_PASSWORD" >> ../store/direktkredit/passwords.env

envsubst < config/db.env > ../store/direktkredit/db.env
envsubst < config/web.env > ../store/direktkredit/web.env

envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/direktkredit/web.env
fi

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" build
docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" up -d

if [ -f "../$HABIDAT_LOGO" ]
then
	docker cp "../$HABIDAT_LOGO" $HABIDAT_DOCKER_PREFIX-direktkredit:/habidat/public/images
fi

