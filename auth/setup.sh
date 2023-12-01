#!/bin/bash
set +x

source ../store/nginx/networks.env

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

mkdir -p ../store/auth/bootstrap
if [ $HABIDAT_SSO == "true" ]
then
	mkdir -p ../store/auth/sso-config
	mkdir -p ../store/auth/cert/saml
fi

echo "Generating passwords..."

# generate passwords
export HABIDAT_USER_SESSION_SECRET="$(openssl rand -base64 32)"
export HABIDAT_LDAP_READ_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_CONFIG_PASSWORD="$(openssl rand -base64 32)"
if [ $HABIDAT_ADMIN_PASSWORD == "generate" ]
then
	export HABIDAT_ADMIN_PASSWORD="$(openssl rand -base64 12)"
fi

# store passwords file
echo "export HABIDAT_LDAP_ADMIN_PASSWORD=$HABIDAT_LDAP_ADMIN_PASSWORD" > ../store/auth/passwords.env
echo "export HABIDAT_LDAP_READ_PASSWORD=$HABIDAT_LDAP_READ_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_LDAP_CONFIG_PASSWORD=$HABIDAT_LDAP_CONFIG_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_ADMIN_PASSWORD=$HABIDAT_ADMIN_PASSWORD" >> ../store/auth/passwords.env

if [ $HABIDAT_SSO == "true" ]
then

	# generalte SSO certificates
	echo "Generating SSO key and certificate..."
	openssl req -new -x509 -days 3652 -nodes -out ../store/auth/cert/saml/cert.cer -keyout ../store/auth/cert/saml/key.pem -subj "/C=AT/ST=Upper Austria/L=Linz/O=habiDAT/OU=SSO/CN=$HABIDAT_DOMAIN"
	chown -R www-data:www-data ../store/auth/cert

	export HABIDAT_SSO_CERTIFICATE=$(cat ../store/auth/cert/saml/cert.cer | sed --expression=':a;N;$!ba;s/\n/\\n/g')
	echo "export HABIDAT_SSO_CERTIFICATE='$HABIDAT_SSO_CERTIFICATE'" >> ../store/auth/passwords.env

	export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE=$(cat ../store/auth/cert/saml/cert.cer| sed --expression=':a;N;$!ba;s/\n//g' | sed --expression='s/-----BEGIN CERTIFICATE-----//g' | sed --expression='s/-----END CERTIFICATE-----//g')
	echo "export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE='$HABIDAT_SSO_CERTIFICATE_SINGLE_LINE'" >> ../store/auth/passwords.env
fi

# set installed modules
export HABIDAT_USER_INSTALLED_MODULES="nginx,auth,"


# TODO ????
echo "Create environment files..."
if [ $HABIDAT_SSO == "true" ]
then
	envsubst < config/sso.env > ../store/auth/sso.env
	envsubst < config/sso.yml > ../store/auth/sso.yml
fi

envsubst < config/ldap.env > ../store/auth/ldap.env
envsubst < config/user.env > ../store/auth/user.env
envsubst < config/bootstrap.ldif > ../store/auth/bootstrap/bootstrap.ldif
cp config/memberOf.ldif ../store/auth/memberOf.ldif

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
	echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/auth/user.env
fi

if [ -z $HABIDAT_EXISTING_BACKEND_NETWORK ]
then
	export HABIDAT_BACKEND_NETWORK="$HABIDAT_DOCKER_PREFIX-backend"
	export HABIDAT_EXTERNAL_NETWORK_DISABLE='#'
	export HABIDAT_INTERNAL_NETWORK_DISABLE=
else
	export HABIDAT_BACKEND_NETWORK="$HABIDAT_EXISTING_BACKEND_NETWORK"
	export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
	export HABIDAT_EXTERNAL_NETWORK_DISABLE=
fi
echo "export HABIDAT_BACKEND_NETWORK=$HABIDAT_BACKEND_NETWORK" >> ../store/nginx/networks.env


envsubst < docker-compose.yml > ../store/auth/docker-compose.yml

echo "Spinning up containers..."

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" build
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d


