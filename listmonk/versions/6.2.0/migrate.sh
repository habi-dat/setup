#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

# shellcheck disable=SC1091
source ../store/nginx/networks.env
# shellcheck disable=SC1091
source ../store/auth/passwords.env

migrate_one() {
  local id="$1"
  echo "Updating listmonk instance ${id}..."
  listmonk_load_instance "$id"

  render_versioned_template listmonk "$HABIDAT_MIGRATE_VERSION" \
    docker-compose.yml.j2 "$(listmonk_compose "$id")"
  render_versioned_template listmonk "$HABIDAT_MIGRATE_VERSION" \
    config/db.env.j2 "$(listmonk_instance_dir "$id")/db.env"
  render_versioned_template listmonk "$HABIDAT_MIGRATE_VERSION" \
    config/listmonk.env.j2 "$(listmonk_instance_dir "$id")/listmonk.env"
  render_versioned_template listmonk "$HABIDAT_MIGRATE_VERSION" \
    config/config.toml.j2 "$(listmonk_instance_dir "$id")/config.toml"

  if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
    if ! grep -q '^CERT_NAME=' "$(listmonk_instance_dir "$id")/listmonk.env"; then
      echo "CERT_NAME=${HABIDAT_DOMAIN}" >> "$(listmonk_instance_dir "$id")/listmonk.env"
    fi
    # shellcheck source=../../../lib/selfsigned-cert.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/selfsigned-cert.sh"
    habidat_ensure_selfsigned_cert
    cp "$(mkcert -CAROOT)/rootCA.pem" "$(listmonk_instance_dir "$id")/mkcert-root.crt"
  fi

  docker compose -f "$(listmonk_compose "$id")" -p "$(listmonk_project "$id")" pull
  docker compose -f "$(listmonk_compose "$id")" -p "$(listmonk_project "$id")" up -d
  echo "Listmonk ${id}: image pulled and recreated (--upgrade runs on container start)."
}

if [[ $# -eq 1 ]]; then
  migrate_one "$1"
else
  listmonk_each_instance migrate_one
fi
