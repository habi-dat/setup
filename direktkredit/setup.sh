#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env

git clone https://github.com/soudis/habidat-direktkredit-platform.git ../store/direktkredit

envsubst < config/settings.env > ../store/direktkredit/settings.env
envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

echo "Spinning up containers..."

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" up -d

# update nextcloud external sites
echo "Add link to nextcloud..."

sed -i '/HABIDAT_DIREKTKREDIT_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_DIREKTKREDIT_SUBDOMAIN=$HABIDAT_DIREKTKREDIT_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh direktkredit