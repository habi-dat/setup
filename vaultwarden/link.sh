#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): writes Vaultwarden's login app to auth from
# store/vaultwarden/. Safe to repeat; an existing app only gets its OIDC client
# settings updated.

# shellcheck source=../lib/auth-app.sh
source ../lib/auth-app.sh

# shellcheck disable=SC1091
source ../store/vaultwarden/passwords.env
export HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET

mkdir -p ../store/auth/user-import
../lib/render.py config/auth-app.json.j2 ../store/auth/user-import/appStore-vaultwarden.json
auth_app_link ../store/auth/user-import/appStore-vaultwarden.json
