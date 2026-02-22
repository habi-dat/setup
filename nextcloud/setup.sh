#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env

mkdir -p ../store/nextcloud

echo "Generating passwords..."

export HABIDAT_NEXTCLOUD_DB_PASSWORD="$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c32)"
export HABIDAT_NEXTCLOUD_ADMIN_PASSWORD="$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c32)"
export HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD="$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c32)"
export HABIDAT_NEXTCLOUD_REDIS_PASSWORD="$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c32)"
export HABIDAT_DISCOURSE_SSO_SECRET="$(< /dev/urandom tr -dc _A-Za-z0-9 | head -c32)"

echo "export HABIDAT_NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" > ../store/nextcloud/passwords.env
echo "export HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" >> ../store/nextcloud/passwords.env
echo "export HABIDAT_NEXTCLOUD_REDIS_PASSWORD=$HABIDAT_NEXTCLOUD_REDIS_PASSWORD" >> ../store/nextcloud/passwords.env
echo "export HABIDAT_DISCOURSE_SSO_SECRET=$HABIDAT_DISCOURSE_SSO_SECRET" >> ../store/nextcloud/passwords.env

echo "Copying assets to store..."
rm -rf ../store/nextcloud/assets
cp -r assets ../store/nextcloud/assets
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

j2 config/db.env.j2 -o ../store/nextcloud/db.env
j2 config/nextcloud.env.j2 -o ../store/nextcloud/nextcloud.env

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
fi

j2 docker-compose.yml.j2 -o ../store/nextcloud/docker-compose.yml

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Spinning up containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

echo "Waiting for containers to start (30 seconds)..."
sleep 30

echo "Installing dependencies in container..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec nextcloud bash -c \
  "apt-get update && apt-get -y install jq && apt-get clean && rm -rf /var/lib/apt/lists/*"

echo "Configuring nextcloud..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-bootstrap.sh
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-add-externalsite.sh user

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec db mysql -u nextcloud --password="$HABIDAT_NEXTCLOUD_DB_PASSWORD" -e "insert into oc_ldap_group_mapping (ldap_dn, owncloud_name, directory_uuid) values ('cn=admins,ou=groups,$HABIDAT_LDAP_BASE', 'admin', 'admin')" nextcloud

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" restart nextcloud

echo "Configuring auth module..."
touch ../store/auth/auth.env
sed -i '/NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/auth.env
sed -i '/NEXTCLOUD_API_URL=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_SSO_SECRET=/d' ../store/auth/auth.env

echo "NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/auth.env
echo "NEXTCLOUD_API_URL=http://admin:$HABIDAT_ADMIN_PASSWORD@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php" >> ../store/auth/auth.env
echo "DISCOURSE_SSO_SECRET=$HABIDAT_DISCOURSE_SSO_SECRET" >> ../store/auth/auth.env
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d
