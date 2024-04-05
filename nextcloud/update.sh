#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

# NEXTCLOUD 19 specific
if ! grep -q HABIDAT_NEXTCLOUD_REDIS_PASSWORD "../store/nextcloud/passwords.env"; then
  export HABIDAT_NEXTCLOUD_REDIS_PASSWORD="$(openssl rand -base64 32)"
  echo "export HABIDAT_NEXTCLOUD_REDIS_PASSWORD=$HABIDAT_NEXTCLOUD_REDIS_PASSWORD" >> ../store/nextcloud/passwords.env
  echo "REDIS_HOST_PASSWORD=$HABIDAT_NEXTCLOUD_REDIS_PASSWORD" >> ../store/nextcloud/nextcloud.env
fi

envsubst < docker-compose.yml > ../store/nextcloud/docker-compose.yml

echo "Pulling images and recreate containers..."

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" pull
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d

echo "Waiting for containers to start (2 minutes)..."
sleep 120

echo "Installing code fixes..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-afterupdate.sh

echo "DB updates"
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud php occ db:add-missing-indices
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud php occ db:add-missing-columns
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud php occ db:add-missing-primary-keys

echo "Configuring user module..."

# remove nextcloud vars from user module env
sed -i '/HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/user.env
sed -i '/HABIDAT_USER_NEXTCLOUD_API_URL=/d' ../store/auth/user.env

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"    # You can either set a return variable (FASTER) 
}

# rewrite API vars to user module env
echo "HABIDAT_USER_NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/user.env
echo "HABIDAT_USER_NEXTCLOUD_API_URL=http://admin:$(rawurlencode $HABIDAT_ADMIN_PASSWORD)@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php" >> ../store/auth/user.env
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user