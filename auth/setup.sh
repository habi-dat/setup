#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

mkdir -p ../store/auth/bootstrap

# generate passwords
export HABIDAT_LDAP_READ_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_CONFIG_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_ADMIN_PASSWORD="$(openssl rand -base64 12)"

# store passwords file
echo "export HABIDAT_LDAP_ADMIN_PASSWORD=$HABIDAT_LDAP_ADMIN_PASSWORD" > ../store/auth/passwords.env
echo "export HABIDAT_LDAP_READ_PASSWORD=$HABIDAT_LDAP_READ_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_LDAP_CONFIG_PASSWORD=$HABIDAT_LDAP_CONFIG_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_ADMIN_PASSWORD=$HABIDAT_ADMIN_PASSWORD" >> ../store/auth/passwords.env

#envsubst < config/sso.env > ../store/auth/sso.env
envsubst < config/ldap.env > ../store/auth/ldap.env
envsubst < config/user.env > ../store/auth/user.env
# envsubst < user-config.json > ../store/ldap/user-config.json
envsubst < config/bootstrap.ldif > ../store/auth/bootstrap/bootstrap.ldif
# envsubst < sso-config.js > ../store/ldap/sso-config.js

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
#	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
#    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN" \
#    -keyout "../store/nginx/certificates/$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN.crt"

#    echo "CERT_NAME=$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN" >> ../store/auth/user.env
	echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/auth/user.env
fi

envsubst < docker-compose.yml > ../store/auth/docker-compose.yml

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d

echo "habi*DAT admin credentials: username is admin, password is $HABIDAT_ADMIN_PASSWORD"
