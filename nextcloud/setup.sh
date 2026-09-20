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

../lib/render.py config/db.env.j2 ../store/nextcloud/db.env
../lib/render.py config/nextcloud.env.j2 ../store/nextcloud/nextcloud.env
../lib/render.py config/mariadb.cnf.j2 ../store/nextcloud/mariadb.cnf

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/nextcloud/nextcloud.env
fi

../lib/render.py docker-compose.yml.j2 ../store/nextcloud/docker-compose.yml

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Spinning up containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

# The database first: the nextcloud entrypoint will not begin installing until
# it can connect. mariadb 11.8 renamed the client, hence `mariadb` not `mysql`.
../lib/wait-for.sh "Nextcloud database" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T db \
     mariadb -u nextcloud --password='$HABIDAT_NEXTCLOUD_DB_PASSWORD' -e 'select 1' nextcloud"

# Then the application -- but only until `occ` is *usable*, not until Nextcloud is
# installed. habidat installs it itself, further down in habidat-bootstrap.sh
# (`occ maintenance:install`), so waiting for "installed: true" here would block
# forever on something this script has not done yet.
#
# The official image copies the application into /var/www/html on first start,
# which is what the old fixed 30s wait was really gambling on.
#
# `occ status` answering at all is the signal: it requires PHP to load
# Nextcloud's autoloader, config and version.php, so it cannot respond until the
# copy is done. Match "installed" case-insensitively -- before installation occ
# prints "Nextcloud is not installed ..." plus "installed: false", afterwards
# "installed: true". Either proves occ is usable, without depending on its exit
# code in limited mode.
../lib/wait-for.sh "Nextcloud container (occ usable)" 600 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status 2>&1 | grep -qi installed"

echo "Installing dependencies in container..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec nextcloud bash -c \
  "apt-get update && apt-get -y install jq && apt-get clean && rm -rf /var/lib/apt/lists/*"

echo "Configuring nextcloud..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-bootstrap.sh
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-add-externalsite.sh user

# Map LDAP cn=admin onto Nextcloud's built-in admin group (same gid as localadmin).
# ldap_dn_hash is SHA-256 of the DN; lookups ignore rows with a NULL hash.
ADMIN_GROUP_DN="cn=admin,ou=groups,$HABIDAT_LDAP_BASE"
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec db mariadb -u nextcloud --password="$HABIDAT_NEXTCLOUD_DB_PASSWORD" -e "insert into oc_ldap_group_mapping (ldap_dn, owncloud_name, directory_uuid, ldap_dn_hash) values ('$ADMIN_GROUP_DN', 'admin', 'admin', SHA2('$ADMIN_GROUP_DN', 256))" nextcloud

# Nextcloud 34 grants LDAP admin rights via ldapAdminGroup, not via the local admin group membership list.
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ ldap:promote-group -n -y admin

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
