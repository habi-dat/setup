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

../lib/render.py config/db.env.j2 ../store/mailtrain/db.env
../lib/render.py config/public.env.j2 ../store/mailtrain/public.env
../lib/render.py config/sandbox.env.j2 ../store/mailtrain/sandbox.env
../lib/render.py config/mailtrain.env.j2 ../store/mailtrain/mailtrain.env
../lib/render.py config/local-production.yaml.j2 ../store/mailtrain/local-production.yaml

../lib/render.py docker-compose.yml.j2 ../store/mailtrain/docker-compose.yml

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
# nextcloud was just recreated to pick up the new subdomain; the external-site
# helper below calls occ, which fails while it is still starting.
../lib/wait-for.sh "nextcloud" 300 \
  "docker compose -f ../store/nextcloud/docker-compose.yml \
     -p '$HABIDAT_DOCKER_PREFIX-nextcloud' exec -T --user www-data \
     nextcloud php occ status | grep -q 'installed: true'"
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat/habidat-add-externalsite.sh mailtrain
