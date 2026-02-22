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

j2 config/db.env.j2 -o ../store/nextcloud/db.env
j2 config/nextcloud.env.j2 -o ../store/nextcloud/nextcloud.env
j2 config/appStore.json.j2 -o ../store/nextcloud/appStore.json

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
fi

j2 docker-compose.yml.j2 -o ../store/nextcloud/docker-compose.yml

echo "Spinning up containers..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" pull
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" build
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d


echo "Waiting for containers to start (30 seconds)..."
sleep 30

echo "Configuring nextcloud..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-bootstrap.sh
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-fixes.sh
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-add-externalsite.sh user

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec db mysql -u nextcloud --password="$HABIDAT_NEXTCLOUD_DB_PASSWORD" -e "insert into oc_ldap_group_mapping (ldap_dn, owncloud_name, directory_uuid) values ('cn=admins,ou=groups,$HABIDAT_LDAP_BASE', 'admin', 'admin')" nextcloud

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" restart nextcloud

echo "Configuring auth module..."
touch ../store/auth/auth.env
sed -i '/NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/auth.env
sed -i '/NEXTCLOUD_API_URL=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_SSO_SECRET=/d' ../store/auth/auth.env

echo "NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/auth.env
echo "NEXTCLOUD_API_URL=http://admin:$HABIDAT_ADMIN_PASSWORD@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php" >> ../store/auth/auth.env
echo "DISCOURSE_SSO_SECRET=$HABIDAT_DISCOURSE_SSO_SECRET" >> ../store/auth/auth.env
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d
