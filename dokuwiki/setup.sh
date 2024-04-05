#!/bin/bash
set +x

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/dokuwiki

echo "Generating passwords..."

envsubst < config/web.env > ../store/dokuwiki/web.env
envsubst "$(printf '${%s} ' ${!HABIDAT*})"  < config/local.php > ../store/dokuwiki/local.php
envsubst "$(printf '${%s} ' ${!HABIDAT*})"  < config/acl.auth.php > ../store/dokuwiki/acl.auth.php

envsubst < docker-compose.yml > ../store/dokuwiki/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/dokuwiki/web.env
fi

echo "Spinning up containers..."

# docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" build
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" up -d

echo "Configuring..."
docker cp ../store/dokuwiki/local.php "$(docker compose -f ../store/dokuwiki/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-dokuwiki ps -q web)":/dokuwiki/conf
docker cp ../store/dokuwiki/acl.auth.php "$(docker compose -f ../store/dokuwiki/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-dokuwiki ps -q web)":/dokuwiki/conf
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web chown www-data:www-data /dokuwiki/conf/local.php

echo "Installing bootstrap theme..."
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web wget https://github.com/giterlizzi/dokuwiki-template-bootstrap3/archive/v2019-05-22.tar.gz
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web tar -zxvf v2019-05-22.tar.gz
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web mv dokuwiki-template-bootstrap3-2019-05-22 /dokuwiki/lib/tpl/bootstrap3
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web chown -R www-data:www-data /dokuwiki/lib/tpl/bootstrap3

echo "Installing plugins..."
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web wget https://github.com/giterlizzi/dokuwiki-plugin-bootswrapper/archive/v2017-04-07.tar.gz
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web tar -zxvf v2017-04-07.tar.gz
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web mv dokuwiki-plugin-bootswrapper-2017-04-07 /dokuwiki/lib/plugins/bootswrapper
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web chown -R www-data:www-data /dokuwiki/lib/plugins/bootswrapper

docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web apt update 
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web apt install -y unzip 
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web apt clean
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web rm -rf /var/lib/apt/lists/*
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web wget https://codeload.github.com/giterlizzi/dokuwiki-plugin-icons/zip/master -O /icons.zip
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web unzip icons.zip
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web mv dokuwiki-plugin-icons-master /dokuwiki/lib/plugins/icons
docker compose -f ../store/dokuwiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-dokuwiki" exec web chown -R www-data:www-data /dokuwiki/lib/plugins/icons


#docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" exec mailtrain npm install passport-ldapauth
#docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" restart mailtrain

# update nextcloud external sites
echo "Add link to nextcloud..."

sed -i '/HABIDAT_DOKUWIKI_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_DOKUWIKI_SUBDOMAIN=$HABIDAT_DOKUWIKI_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh dokuwiki
