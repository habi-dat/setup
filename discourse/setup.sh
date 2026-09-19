#!/usr/bin/env bash
set -euo pipefail

mkdir -p ../store/discourse

source ../store/nginx/networks.env
source ../store/nextcloud/passwords.env
source ../store/auth/passwords.env

git clone https://github.com/discourse/discourse_docker ../store/discourse

echo "Generating passwords..."

export HABIDAT_DISCOURSE_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_DISCOURSE_ADMIN_PASSWORD="$(openssl rand -base64 12)"

echo "export HABIDAT_DISCOURSE_DB_PASSWORD=$HABIDAT_DISCOURSE_DB_PASSWORD" > ../store/discourse/passwords.env
echo "export HABIDAT_DISCOURSE_ADMIN_PASSWORD=$HABIDAT_DISCOURSE_ADMIN_PASSWORD" >> ../store/discourse/passwords.env

mkdir -p ../store/discourse/bootstrap

j2 config/discourse-settings.yml.j2 -o ../store/discourse/bootstrap/discourse-settings.yml
j2 templates/discourse-data.yml.j2 -o "../store/discourse/containers/$HABIDAT_DOCKER_PREFIX-discourse-data.yml"
j2 templates/discourse.yml.j2 -o "../store/discourse/containers/$HABIDAT_DOCKER_PREFIX-discourse.yml"

echo "Building and starting containers..."

../store/discourse/launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse-data"
../store/discourse/launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse"

docker network connect "$HABIDAT_PROXY_NETWORK" "$HABIDAT_DOCKER_PREFIX-discourse"

echo "Waiting for discourse container to initialize (this can take several minutes)..."
sleep 10
DISCOURSE_IP=$(docker inspect "$HABIDAT_DOCKER_PREFIX-discourse" | grep IPAddress | tail -n1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')

until nc -z "$DISCOURSE_IP" 80; do
  sleep .5
done

echo "Creating admin user..."

{
  echo "$HABIDAT_ADMIN_EMAIL"
  echo "$HABIDAT_ADMIN_PASSWORD"
  echo "$HABIDAT_ADMIN_PASSWORD"
  echo "Y"
} | docker exec -i "$HABIDAT_DOCKER_PREFIX-discourse" rake admin:create

echo "Generating API key and update user service..."

unset HABIDAT_DISCOURSE_API_KEY
export HABIDAT_DISCOURSE_API_KEY=$(echo $(docker exec "$HABIDAT_DOCKER_PREFIX-discourse" rake api_key:create_master[usertool]) | tr -d "\r" | awk '{print $NF}')
while [[ -z "$HABIDAT_DISCOURSE_API_KEY" ]]; do
  sleep .5
done
echo "export HABIDAT_DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/discourse/passwords.env

touch ../store/auth/auth.env
sed -i '/DISCOURSE_API_KEY=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_URL=/d' ../store/auth/auth.env
sed -i '/DISCOURSE_API_USERNAME=/d' ../store/auth/auth.env

echo "DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/auth/auth.env
echo "DISCOURSE_URL=http://$HABIDAT_DOCKER_PREFIX-discourse:80" >> ../store/auth/auth.env
echo "DISCOURSE_API_USERNAME=system" >> ../store/auth/auth.env

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d

echo "Add link to nextcloud..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat/habidat-add-externalsite.sh discourse

echo "Setting theme, app menu and colors..."

curl -k --header "Content-Type: application/json" --header "Accept: application/json" \
        --request POST --data '{"color_scheme": { "base_scheme_id": "Light", "colors": [ { "hex": "212121", "name": "primary" }, { "hex": "fafafa", "name": "secondary" }, { "hex": "448aff", "name": "tertiary" }, { "hex": "e92e4e", "name": "quaternary" }, { "hex": "a40023", "name": "header_background" }, { "hex": "ffffff", "name": "header_primary" }, { "hex": "ffff8d", "name": "highlight" }, { "hex": "ff6d00", "name": "danger" }, { "hex": "4caf50", "name": "success" }, { "hex": "fa6c8d", "name": "love" } ], "name": "habidat"}}' \
        --header "Api-Key: $HABIDAT_DISCOURSE_API_KEY" \
        --header "Api-Username: system" \
        "http://$DISCOURSE_IP/admin/color_schemes.json"

curl -k --header "Content-Type: application/json" --header "Accept: application/json" \
        --request PUT --data '{"theme":{"color_scheme_id": "2", "theme_fields":[{"name":"scss","target":"common","value":"","type_id":1},{"name":"header","target":"common","value":"<script>(function(){var s=document.createElement(\"script\");s.src=\"https://'"$HABIDAT_USER_SUBDOMAIN"'.'"$HABIDAT_DOMAIN"'/api/widget/script\";s.async=true;document.head.appendChild(s);})();</script>","type_id":0}]}}' \
        --header "Api-Key: $HABIDAT_DISCOURSE_API_KEY" \
        --header "Api-Username: system" \
        "http://$DISCOURSE_IP/admin/themes/2"

curl -k --header "Content-Type: application/json" --header "Accept: application/json" \
        --request PUT --data '{"theme":{"color_scheme_id": "0", "theme_fields":[{"name":"scss","target":"common","value":"","type_id":1},{"name":"header","target":"common","value":"<script>(function(){var s=document.createElement(\"script\");s.src=\"https://'"$HABIDAT_USER_SUBDOMAIN"'.'"$HABIDAT_DOMAIN"'/api/widget/script\";s.async=true;document.head.appendChild(s);})();</script>","type_id":0}]}}' \
        --header "Api-Key: $HABIDAT_DISCOURSE_API_KEY" \
        --header "Api-Username: system" \
        "http://$DISCOURSE_IP/admin/themes/1"
