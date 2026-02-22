#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/mailtrain

echo "Generating passwords..."

export HABIDAT_MAILTRAIN_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_MAILTRAIN_DB_PASSWORD=$HABIDAT_MAILTRAIN_DB_PASSWORD" > ../store/mailtrain/passwords.env
echo "export HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD=$HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD" >> ../store/mailtrain/passwords.env

j2 config/db.env.j2 -o ../store/mailtrain/db.env
j2 config/public.env.j2 -o ../store/mailtrain/public.env
j2 config/sandbox.env.j2 -o ../store/mailtrain/sandbox.env
j2 config/mailtrain.env.j2 -o ../store/mailtrain/mailtrain.env
j2 config/local-production.yaml.j2 -o ../store/mailtrain/local-production.yaml

j2 docker-compose.yml.j2 -o ../store/mailtrain/docker-compose.yml

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/public.env
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/sandbox.env
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/mailtrain/mailtrain.env
fi

echo "Spinning up containers..."
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" pull
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" up -d
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" exec mailtrain npm install passport-ldapauth
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" restart mailtrain

echo "Add link to nextcloud..."
sed -i '/HABIDAT_MAILTRAIN_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_MAILTRAIN_SUBDOMAIN=$HABIDAT_MAILTRAIN_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
sleep 5
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh mailtrain
