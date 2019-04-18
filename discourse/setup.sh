#!/bin/bash
set +x

mkdir -p ../store/discourse

source ../store/nextcloud/passwords.env

#export HABIDAT_TITLE='habi*DAT'
#export HABIDAT_DESCRIPTION='habi*DAT Test Plattform fuer Hausprojekte'
#export HABIDAT_EMAIL='support@xaok.org'
#export HABIDAT_PROTOCOL="https"
#export HABIDAT_NEXTCLOUD_SUBDOMAIN="cloud"
#export HABIDAT_DOMAIN="habidat-staging"
#export HABIDAT_DISCOURSE_SUBDOMAIN="discourse"
#export HABIDAT_DISCOURSE_SSO_SECRET="2134upiohasdf0dsf01ks89274309h"
#export HABIDAT_LDAP_BASE="dc=habidat-staging"
#export HABIDAT_LDAP_READ_USER="ldap-read"
#export HABIDAT_LDAP_READ_PASSWORD="dDD2TNM6kHuUeC4n"

echo "Generating passwords..."

export HABIDAT_DISCOURSE_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_DISCOURSE_ADMIN_PASSWORD="$(openssl rand -base64 12)"

echo "export HABIDAT_DISCOURSE_DB_PASSWORD=$HABIDAT_DISCOURSE_DB_PASSWORD" > ../store/discourse/passwords.env
echo "export HABIDAT_DISCOURSE_ADMIN_PASSWORD=$HABIDAT_DISCOURSE_ADMIN_PASSWORD" >> ../store/discourse/passwords.env

envsubst < config/db.env > ../store/discourse/db.env
envsubst < config/discourse.env > ../store/discourse/discourse.env

envsubst < docker-compose.yml > ../store/discourse/docker-compose.yml

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/discourse/discourse.env
    echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/discourse/discourse.env
fi

echo "Spinning up containers..."

docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" up -d

echo "Waiting for discourse container to initialize (this can take several minutes)..."
# wait until discourse bootstrap is done
until nc -z $(docker inspect "$HABIDAT_DOCKER_PREFIX-discourse" | grep IPAddress | tail -n1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}') 3000
do
	sleep .5	
done

echo "Configuring discourse..."

envsubst < config/discourse-settings.yml > ../store/discourse/discourse-settings.yml
docker cp ../store/discourse/discourse-settings.yml "$(docker-compose -f ../store/discourse/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-discourse ps -q discourse)":/
docker cp setup-discourse-container.sh "$(docker-compose -f ../store/discourse/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-discourse ps -q discourse)":/
docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" exec discourse chmod +x /setup-discourse-container.sh
docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" exec discourse bash -c "/setup-discourse-container.sh"

echo "Generating API key and update user service..."

export HABIDAT_DISCOURSE_API_KEY=$(echo $(docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bundle exec rake -s -f /opt/bitnami/discourse/Rakefile api_key:get) | tr -d "\r" | awk '{print $NF}')
echo "export HABIDAT_DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/discourse/passwords.env

# remove API vars from user module env
sed -i '/HABIDAT_DISCOURSE_API_KEY/d' ../store/auth/user.env
sed -i '/HABIDAT_DISCOURSE_API_URL/d' ../store/auth/user.env
sed -i '/HABIDAT_DISCOURSE_API_USERNAME/d' ../store/auth/user.env

# rewrite API vars to user module env
echo "HABIDAT_DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY" >> ../store/auth/user.env
echo "HABIDAT_DISCOURSE_API_URL=http://$HABIDAT_DOCKER_PREFIX-discourse:3000" >> ../store/auth/user.env
echo "HABIDAT_DISCOURSE_API_USERNAME=admin" >> ../store/auth/user.env

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user


echo "Theming..."
# set colors
curl -k --header "Content-Type: application/json" \
        --request POST --data '{"color_scheme": { "base_scheme_id": "default", "colors": [ { "hex": "212121", "name": "primary" }, { "hex": "fafafa", "name": "secondary" }, { "hex": "448aff", "name": "tertiary" }, { "hex": "e92e4e", "name": "quaternary" }, { "hex": "a40023", "name": "header_background" }, { "hex": "ffffff", "name": "header_primary" }, { "hex": "ffff8d", "name": "highlight" }, { "hex": "ff6d00", "name": "danger" }, { "hex": "4caf50", "name": "success" }, { "hex": "fa6c8d", "name": "love" } ], "name": "habidat"}}' \
        "$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN/admin/color_schemes.json?api_username=admin&api_key=$HABIDAT_DISCOURSE_API_KEY"

curl -k --header "Content-Type: application/json" \
        --request PUT --data '{"theme": {"color_scheme_id": "2" }}' \
        "$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN/admin/themes/2?api_username=admin&api_key=$HABIDAT_DISCOURSE_API_KEY"

echo

docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" restart discourse



#docker-compose -f ../nextcloud/docker-compose.yml exec --user www-data nextcloud php occ config:app:set discoursesso clientsecret --value="$HABIDAT_DISCOURSE_SSO_SECRET"
#docker-compose -f ../nextcloud/docker-compose.yml exec --user www-data nextcloud php occ config:app:set discoursesso clienturl --value="$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN"
#docker-compose -f ../nextcloud/docker-compose.yml exec --user www-data nextcloud php occ app:install discoursesso
#docker-compose -f ../nextcloud/docker-compose.yml exec --user www-data nextcloud php occ app:enable discoursesso

#export APPDATA_DIR=$(docker-compose -f ../nextcloud/docker-compose.yml exec nextcloud find /var/www/html/data/ -type d -regex "/var/www/html/data/appdata[^/]*" | tr -d "\r")
#export CONTAINER_ID=$(docker-compose -f ../nextcloud/docker-compose.yml ps -q nextcloud)
#docker cp discourse.ico "$CONTAINER_ID":"$APPDATA_DIR/external/icons"

#docker-compose exec --user www-data nextcloud php occ config:app:set external sites --value "{\"1\":{\"icon\":\"discourse.ico\",\"lang\":\"\",\"type\":\"link\",\"device\":\"\",\"id\":1,\"name\":\"Discourse\",\"url\":\"$HABIDAT_PROTOCOL:\/\/$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN\"},\"2\":{\"icon\":\"wiki.png\",\"lang\":\"\",\"type\":\"link\",\"device\":\"\",\"id\":2,\"name\":\"Wiki\",\"url\":\"$HABIDAT_PROTOCOL:\/\/$HABIDAT_WIKI_SUBDOMAIN.$HABIDAT_DOMAIN\"},\"3\":{\"icon\":\"user.png\",\"lang\":\"\",\"type\":\"link\",\"device\":\"\",\"id\":3,\"name\":\"User*innen\",\"url\":\"$HABIDAT_PROTOCOL:\/\/$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN\"}}"	


#envsubst < discourse_site_settings.json.template > discourse-site-settings.json
#git clone https://github.com/pfaffman/discourse-settings-uploader.git 
#gem install rdoc rest-client
#discourse-settings-uploader/discourse-settings-uploader discourse.habidat-staging "$(echo $(docker-compose exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bundle exec rake fapi_key:get) | tr -d "\r" | awk '{print $NF}')" admin discourse-site-settings.json

#settings-uploader/discourse-settings-uploader localhost "$(echo $(bundle exec rake api_key:get) | tr -d "\r" | awk '{print $NF}')" admin discourse-site-settings.json