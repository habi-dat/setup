#!/bin/bash
set -e

usage(){
	echo "./habidat.sh install mediawiki <Project ID / Subdomain> <Project Title> <LDAP Group>"
	exit 1
}


[[ $# -lt 3 ]] && usage

if [ -d "../store/mediawiki/$1" ]
then
	echo "Mediawiki instance $1 already exists, aborting..."
	exit 1
fi

echo "Installing medaiwiki instance $1..."

source ../store/nginx/networks.env
source ../store/auth/passwords.env

export HABIDAT_MEDIAWIKI_PROJECTID="$1"
export HABIDAT_MEDIAWIKI_TITLE="$2"
export HABIDAT_MEDIAWIKI_LDAP_GROUP="$3"

mkdir -p ../store/mediawiki/$1

echo "Generating passwords..."

export HABIDAT_MEDIAWIKI_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_MEDIAWIKI_DB_PASSWORD=$HABIDAT_MEDIAWIKI_DB_PASSWORD" > ../store/mediawiki/$1/passwords.env
echo "export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD=$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" >> ../store/mediawiki/$1/passwords.env


if [ $HABIDAT_SSO == "true" ]
then

	export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE=$(cat ../store/auth/cert/server.cert | sed --expression=':a;N;$!ba;s/\n//g' | sed --expression='s/-----BEGIN CERTIFICATE-----//g' | sed --expression='s/-----END CERTIFICATE-----//g')
	echo "export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE='$HABIDAT_SSO_CERTIFICATE_SINGLE_LINE'" >> ../store/auth/passwords.env
fi


envsubst < config/db.env > ../store/mediawiki/$1/db.env
envsubst < config/web.env > ../store/mediawiki/$1/web.env

envsubst < docker-compose.yml > ../store/mediawiki/$1/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mediawiki/$1/web.env
fi

echo "Spinning up containers..."

docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" pull
docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" build 
docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" up -d db
echo "Waiting for database to initialize..."
sleep 20
docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" up -d web

echo "Waiting for mediawiki container to initialize (this can take several minutes)..."
# wait until discourse bootstrap is done

until [ -e $(docker volume inspect --format '{{ .Mountpoint }}' $HABIDAT_DOCKER_PREFIX-mediawiki-$1_config)/INSTALLED ]
do
	sleep .5	
done

echo "Add logo..."

if [ -f "../$HABIDAT_LOGO" ]
then
	docker cp "../$HABIDAT_LOGO" $HABIDAT_DOCKER_PREFIX-mediawiki-$1:/var/www/html/images
fi
docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" exec --user www-data web php maintenance/importImages.php images

echo "Mediawiki instance $1 successfully installed! Please add nextcloud link and entry in auth/sso.yml manually."

# update nextcloud external sites
#echo "Add link to nextcloud..."

#sed -i '/HABIDAT_MEDIAWIKI_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
#echo "HABIDAT_MEDIAWIKI_SUBDOMAIN=$HABIDAT_MEDIAWIKI_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
#docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
#sleep 5
#docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh mediawiki
