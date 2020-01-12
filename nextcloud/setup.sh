#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/nextcloud

echo "Generating passwords..."

#export HABIDAT_LDAP_BASE="dc=habidat-staging"
export HABIDAT_NEXTCLOUD_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_NEXTCLOUD_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_DISCOURSE_SSO_SECRET="$(openssl rand -base64 32)"

# store passwords file
echo "export HABIDAT_NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" > ../store/nextcloud/passwords.env
echo "export HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" >> ../store/nextcloud/passwords.env
echo "export HABIDAT_DISCOURSE_SSO_SECRET=$HABIDAT_DISCOURSE_SSO_SECRET" >> ../store/nextcloud/passwords.env

envsubst < config/db.env > ../store/nextcloud/db.env
envsubst < config/nextcloud.env > ../store/nextcloud/nextcloud.env


#export HABIDAT_NEXTCLOUD_SUBDOMAIN="cloud"
#export HABIDAT_DOMAIN="habidat-staging"
#export HABIDAT_PROTOCOL="http"
#export HABIDAT_USER_SUBDOMAIN="user"
#export HABIDAT_DISCOURSE_SUBDOMAIN="discourse"
#export HABIDAT_DISCOURSE_SSO_SECRET="$(openssl rand -base64 32)"
#export HABIDAT_DK_SUBDOMAIN="direktskredit"
#export HABIDAT_DK_ENABLE=true
#export HABIDAT_TITLE='habi*DAT'
#export HABIDAT_DESCRIPTION='habi*DAT Test Plattform fuer Hausprojekte'
#export HABIDAT_WIKI_SUBDOMAIN="wiki"

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
fi

envsubst < docker-compose.yml > ../store/nextcloud/docker-compose.yml

echo "Spinning up containers..."

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" pull
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" build
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d
echo "Waiting for containers to start (2 minutes)..."
sleep 120
# wait until nextcloud bootstrap is done
#until nc -z $(docker inspect "$HABIDAT_DOCKER_PREFIX-nextcloud" | grep IPAddress | tail -n1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}') 80
#do
#	sleep .5	
#done
#docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX" exec --user www-data nextcloud php occ maintenance:install --database "mysql" --database-host "db" --database-name "nextcloud"  --database-user "nextcloud" --database-pass "$HABIDAT_NEXTCLOUD_DB_PASSWORD" --admin-user "admin" --admin-pass "$HABIDAT_NEXTCLOUD_ADMIN_PASSWORD"

echo "Configuring nextcloud..."
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-bootstrap.sh
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-fixes.sh
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh user

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec db mysql -u nextcloud --password="$HABIDAT_NEXTCLOUD_DB_PASSWORD" -e "insert into oc_ldap_group_mapping (ldap_dn, owncloud_name, directory_uuid) values ('cn=admins,ou=groups,$HABIDAT_LDAP_BASE', 'admin', 'admin')" nextcloud 

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" restart nextcloud

echo "Configuring user module..."

HABIDAT_USER_NEXTCLOUD_API_URL=https://$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN

# remove nextcloud vars from user module env
sed -i '/HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/user.env
sed -i '/HABIDAT_USER_NEXTCLOUD_API_URL=/d' ../store/auth/user.env

# rewrite API vars to user module env
echo "HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/user.env
echo "HABIDAT_USER_NEXTCLOUD_API_URL=https://admin:$HABIDAT_ADMIN_PASSWORD@$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN/ocs/v1.php" >> ../store/auth/user.env
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user