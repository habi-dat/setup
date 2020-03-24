#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

envsubst < docker-compose.yml > ../store/nextcloud/docker-compose.yml

echo "Pulling images and recreate containers..."

docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" pull
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d

echo "Installing code fixes..."
docker-compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-fixes.sh

echo "Configuring user module..."

# remove nextcloud vars from user module env
sed -i '/HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/user.env
sed -i '/HABIDAT_USER_NEXTCLOUD_API_URL=/d' ../store/auth/user.env

# rewrite API vars to user module env
echo "HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/user.env
echo "HABIDAT_USER_NEXTCLOUD_API_URL=http://admin:$HABIDAT_ADMIN_PASSWORD@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php" >> ../store/auth/user.env
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user