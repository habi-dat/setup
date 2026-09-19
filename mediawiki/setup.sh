#!/usr/bin/env bash
set -euo pipefail

usage(){
  echo "./habidat.sh install mediawiki <Project ID / Subdomain> <Project Title> <LDAP Group>"
  exit 1
}

[[ $# -lt 3 ]] && usage

if [[ ! "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo "Project ID must be a DNS label (letters, numbers, hyphens)."
  exit 1
fi

if [[ -d "../store/mediawiki/$1" ]]; then
  echo "Mediawiki instance $1 already exists, aborting..."
  exit 1
fi

echo "Installing mediawiki instance $1..."

source ../store/nginx/networks.env
source ../store/auth/passwords.env

export HABIDAT_MEDIAWIKI_PROJECTID="$1"
export HABIDAT_MEDIAWIKI_TITLE="$2"
export HABIDAT_MEDIAWIKI_LDAP_GROUP="$3"

mkdir -p "../store/mediawiki/$1"

echo "Generating passwords..."

export HABIDAT_MEDIAWIKI_DB_PASSWORD="$(openssl rand -base64 32)"
export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

echo "export HABIDAT_MEDIAWIKI_DB_PASSWORD=$HABIDAT_MEDIAWIKI_DB_PASSWORD" > "../store/mediawiki/$1/passwords.env"
echo "export HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD=$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" >> "../store/mediawiki/$1/passwords.env"

if [[ -z "${HABIDAT_SSO_CERTIFICATE_SINGLE_LINE:-}" ]]; then
  SAML_CERT="../store/auth/cert/saml/cert.cer"
  if [[ -f "$SAML_CERT" ]]; then
    HABIDAT_SSO_CERTIFICATE_SINGLE_LINE=$(cat "$SAML_CERT" | sed --expression=':a;N;$!ba;s/\n//g' | sed --expression='s/-----BEGIN CERTIFICATE-----//g' | sed --expression='s/-----END CERTIFICATE-----//g')
    export HABIDAT_SSO_CERTIFICATE_SINGLE_LINE
  else
    echo "Auth SAML certificate not found (expected $SAML_CERT or HABIDAT_SSO_CERTIFICATE_SINGLE_LINE in passwords.env)."
    rm -rf "../store/mediawiki/$1"
    exit 1
  fi
fi

j2 config/db.env.j2 -o "../store/mediawiki/$1/db.env"
j2 config/web.env.j2 -o "../store/mediawiki/$1/web.env"

j2 docker-compose.yml.j2 -o "../store/mediawiki/$1/docker-compose.yml"

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=$HABIDAT_DOMAIN" >> "../store/mediawiki/$1/web.env"
fi

echo "Registering MediaWiki SAML app in habidat-auth..."
if [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "habidat-auth is not installed (missing store/auth/docker-compose.yml)."
  rm -rf "../store/mediawiki/$1"
  exit 1
fi
mkdir -p ../store/auth/user-import
j2 config/auth-app.json.j2 -o "../store/auth/user-import/appStore-mediawiki-$1.json"
if ! docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init; then
  echo "Failed to register MediaWiki SAML app in habidat-auth."
  rm -f "../store/auth/user-import/appStore-mediawiki-$1.json"
  rm -rf "../store/mediawiki/$1"
  exit 1
fi

echo "Spinning up containers..."

docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" pull
docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" build
docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" up -d db
echo "Waiting for database to initialize..."
sleep 20
docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" up -d web

echo "Waiting for mediawiki container to initialize (this can take several minutes)..."

until [[ -e $(docker volume inspect --format '{{ .Mountpoint }}' "$HABIDAT_DOCKER_PREFIX-mediawiki-${1}_config")/INSTALLED ]]; do
  sleep .5
done

echo "Add logo..."

if [[ -f "../$HABIDAT_LOGO" ]]; then
  docker cp "../$HABIDAT_LOGO" "$HABIDAT_DOCKER_PREFIX-mediawiki-$1:/var/www/html/images"
fi
docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" exec --user www-data web php maintenance/importImages.php images

echo "Mediawiki instance $1 successfully installed (SAML app slug: $1.${HABIDAT_MEDIAWIKI_SUBDOMAIN:-mediawiki})."
