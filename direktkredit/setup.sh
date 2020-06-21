#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env

git clone https://github.com/soudis/habidat-direktkredit-platform.git ../store/direktkredit

envsubst < config/settings.env > ../store/direktkredit/settings.env
envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/direktkredit/settings.env
fi

echo "Spinning up containers..."

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" up -d


echo "Add project logo..."

if [ -f "../$HABIDAT_LOGO" ]
then
	docker cp "../$HABIDAT_LOGO" $HABIDAT_DOCKER_PREFIX-direktkredit:/habidat/public/images
fi

# update nextcloud external sites
echo "Add link to nextcloud..."

sed -i '/HABIDAT_DIREKTKREDIT_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_DIREKTKREDIT_SUBDOMAIN=$HABIDAT_DIREKTKREDIT_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh direktkredit