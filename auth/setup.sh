#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env

mkdir -p ../store/auth/bootstrap
mkdir -p ../store/auth/user-import
if [[ "${HABIDAT_SSO:-false}" == "true" ]]; then
  mkdir -p ../store/auth/sso-config
  mkdir -p ../store/auth/cert/saml
fi

echo "Generating passwords..."

export HABIDAT_USER_SESSION_SECRET="$(openssl rand -base64 32)"
export HABIDAT_LDAP_READ_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_LDAP_CONFIG_PASSWORD="$(openssl rand -base64 32)"
if [[ "${HABIDAT_ADMIN_PASSWORD:-}" == "generate" ]]; then
  export HABIDAT_ADMIN_PASSWORD="$(openssl rand -base64 12)"
fi

echo "export HABIDAT_LDAP_ADMIN_PASSWORD=$HABIDAT_LDAP_ADMIN_PASSWORD" > ../store/auth/passwords.env
echo "export HABIDAT_LDAP_READ_PASSWORD=$HABIDAT_LDAP_READ_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_LDAP_CONFIG_PASSWORD=$HABIDAT_LDAP_CONFIG_PASSWORD" >> ../store/auth/passwords.env
echo "export HABIDAT_ADMIN_PASSWORD=$HABIDAT_ADMIN_PASSWORD" >> ../store/auth/passwords.env

if [[ "${HABIDAT_SSO:-false}" == "true" ]]; then
  echo "Generating SSO key and certificate..."
  openssl req -new -x509 -days 3652 -nodes \
    -out ../store/auth/cert/saml/cert.cer \
    -keyout ../store/auth/cert/saml/key.pem \
    -subj "/C=AT/ST=Upper Austria/L=Linz/O=habiDAT/OU=SSO/CN=$HABIDAT_DOMAIN"
  chmod a+r ../store/auth/cert/saml/cert.cer
  chmod a+r ../store/auth/cert/saml/key.pem

  export HABIDAT_SSO_CERTIFICATE=$(cat ../store/auth/cert/saml/cert.cer | sed --expression=':a;N;$!ba;s/\n/\\n/g')
  echo "export HABIDAT_SSO_CERTIFICATE='$HABIDAT_SSO_CERTIFICATE'" >> ../store/auth/passwords.env

  export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE=$(cat ../store/auth/cert/saml/cert.cer | sed --expression=':a;N;$!ba;s/\n//g' | sed --expression='s/-----BEGIN CERTIFICATE-----//g' | sed --expression='s/-----END CERTIFICATE-----//g')
  echo "export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE='$HABIDAT_SSO_CERTIFICATE_SINGLE_LINE'" >> ../store/auth/passwords.env
fi

export HABIDAT_USER_INSTALLED_MODULES="nginx,auth,"

echo "Creating environment files..."
if [[ "${HABIDAT_SSO:-false}" == "true" ]]; then
  j2 config/sso.env.j2 -o ../store/auth/sso.env
  j2 config/sso.yml.j2 -o ../store/auth/sso.yml
fi

j2 config/ldap.env.j2 -o ../store/auth/ldap.env
j2 config/user.env.j2 -o ../store/auth/user.env
set -a
source ../store/auth/passwords.env
source ../store/auth/user.env
set +a

AUTH_ENV="../store/auth/auth.env"
POSTGRES_PASSWORD=$(openssl rand -hex 24)
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" > "$AUTH_ENV"
echo "DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@user-db:5432/habidat_auth" >> "$AUTH_ENV"
echo "REDIS_URL=redis://user-redis:6379" >> "$AUTH_ENV"
HOST="${HABIDAT_USER_SUBDOMAIN:-user}.${HABIDAT_DOMAIN:-habidat.local}"
PROTO="${HABIDAT_PROTOCOL:-https}"
echo "APP_URL=${PROTO}://${HOST}" >> "$AUTH_ENV"
echo "NEXT_PUBLIC_APP_URL=${PROTO}://${HOST}" >> "$AUTH_ENV"
echo "TRUSTED_ORIGINS=${PROTO}://*.${HABIDAT_DOMAIN:-habidat.local}" >> "$AUTH_ENV"
echo "SESSION_SECRET=$HABIDAT_USER_SESSION_SECRET" >> "$AUTH_ENV"
echo "BETTER_AUTH_SECRET=$HABIDAT_USER_SESSION_SECRET" >> "$AUTH_ENV"
echo "ADMIN_EMAIL=$HABIDAT_ADMIN_EMAIL" >> "$AUTH_ENV"
echo "ADMIN_PASSWORD=$HABIDAT_ADMIN_PASSWORD" >> "$AUTH_ENV"
echo "LDAP_URL=ldap://${HABIDAT_USER_LDAP_HOST:-ldap}:${HABIDAT_USER_LDAP_PORT:-389}" >> "$AUTH_ENV"
echo "LDAP_BIND_DN=$HABIDAT_USER_LDAP_BINDDN" >> "$AUTH_ENV"
echo "LDAP_BIND_PASSWORD=$HABIDAT_USER_LDAP_PASSWORD" >> "$AUTH_ENV"
echo "LDAP_BASE_DN=$HABIDAT_USER_LDAP_BASE" >> "$AUTH_ENV"
echo "LDAP_USERS_DN=ou=users,$HABIDAT_USER_LDAP_BASE" >> "$AUTH_ENV"
echo "LDAP_GROUPS_DN=ou=groups,$HABIDAT_USER_LDAP_BASE" >> "$AUTH_ENV"
echo "SMTP_HOST=$HABIDAT_USER_SMTP_HOST" >> "$AUTH_ENV"
echo "SMTP_PORT=$HABIDAT_USER_SMTP_PORT" >> "$AUTH_ENV"
echo "SMTP_SECURE=$HABIDAT_USER_SMTP_TLS" >> "$AUTH_ENV"
echo "SMTP_USER=$HABIDAT_USER_SMTP_USER" >> "$AUTH_ENV"
echo "SMTP_PASS=$HABIDAT_USER_SMTP_PASSWORD" >> "$AUTH_ENV"
echo "SMTP_FROM=$HABIDAT_USER_SMTP_EMAILFROM" >> "$AUTH_ENV"
echo "HABIDAT_USER_INSTALLED_MODULES=$HABIDAT_USER_INSTALLED_MODULES" >> "$AUTH_ENV"

j2 config/bootstrap.ldif.j2 -o ../store/auth/bootstrap/bootstrap.ldif
j2 config/memberOf.ldif.j2 -o ../store/auth/memberOf.ldif

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> ../store/auth/user.env
fi

if [[ -z "${HABIDAT_EXISTING_BACKEND_NETWORK:-}" ]]; then
  export HABIDAT_BACKEND_NETWORK="$HABIDAT_DOCKER_PREFIX-backend"
  export HABIDAT_EXTERNAL_NETWORK_DISABLE='#'
  export HABIDAT_INTERNAL_NETWORK_DISABLE=
else
  export HABIDAT_BACKEND_NETWORK="$HABIDAT_EXISTING_BACKEND_NETWORK"
  export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
  export HABIDAT_EXTERNAL_NETWORK_DISABLE=
fi
echo "export HABIDAT_BACKEND_NETWORK=$HABIDAT_BACKEND_NETWORK" >> ../store/nginx/networks.env

if [[ "${HABIDAT_EXPOSE_LDAP:-false}" == "true" ]]; then
  export HABIDAT_LDAP_PORT_MAPPING='127.0.0.1:389:389'
else
  export HABIDAT_LDAP_PORT_MAPPING='389'
fi

j2 docker-compose.yml.j2 -o ../store/auth/docker-compose.yml

echo "Spinning up containers..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user-db user-redis ldap

echo "Running auth-init (migrate + seed)..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init

if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d mailhog
fi

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user user-worker
