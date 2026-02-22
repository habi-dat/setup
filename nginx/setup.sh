#!/usr/bin/env bash
set -euo pipefail

mkdir -p ../store/nginx/certificates
mkdir -p ../store/nginx/config

if [[ -z "${HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK:-}" ]]; then

  echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_DOCKER_PREFIX-proxy" > ../store/nginx/networks.env

  echo "Creating configuration files..."
  j2 docker-compose.yml.j2 -o ../store/nginx/docker-compose.yml
  j2 config/nginx.conf.j2 -o ../store/nginx/config/nginx.conf
  j2 config/user.conf.j2 -o ../store/nginx/config/user.conf
  j2 config/cors_map.conf.j2 -o ../store/nginx/config/cors_map.conf
  j2 config/cookies.conf.j2 -o ../store/nginx/config/cookies.conf

  echo "Spinning up containers..."
  docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" up -d

  if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
    echo "Generating self-signed certificate..."
    mkcert -install -key-file "../store/nginx/certificates/$HABIDAT_DOMAIN.key" \
           -cert-file "../store/nginx/certificates/$HABIDAT_DOMAIN.crt" \
           "*.$HABIDAT_DOMAIN"
  fi

else

  echo "Using existing nginx generator and proxy network, skipping module containers..."
  echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK" > ../store/nginx/networks.env

fi
