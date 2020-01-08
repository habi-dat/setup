#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/mailtrain

echo "Generating passwords..."

export HABIDAT_MAILTRAIN_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_MAILTRAIN_DB_PASSWORD=$HABIDAT_DK_DB_PASSWORD" > ../store/mailtrain/passwords.env
echo "export HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD=$HABIDAT_DK_DB_ROOT_PASSWORD" >> ../store/mailtrain/passwords.env

envsubst < config/db.env > ../store/mailtrain/db.env
envsubst < config/public.env > ../store/mailtrain/public.env
envsubst < config/sandbox.env > ../store/mailtrain/sandbox.env
envsubst < config/mailtrain.env > ../store/mailtrain/mailtrain.env
envsubst < config/local-production.yaml > ../store/mailtrain/local-production.yaml

envsubst < docker-compose.yml > ../store/mailtrain/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/public.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/sandbox.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/mailtrain.env
fi

echo "Spinning up containers..."

# docker-compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" build
docker-compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" pull
docker-compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" up -d
docker-compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" exec mailtrain npm install passport-ldapauth
docker-compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" restart mailtrain

# update nextcloud external sites
echo "Add link to nextcloud..."

sed -i '/HABIDAT_MAILTRAIN_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_MAILTRAIN_SUBDOMAIN=$HABIDAT_MAILTRAIN_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh mailtrain
