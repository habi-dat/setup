#!/usr/bin/env bash
# Apply SMTP, OIDC and privacy via the Listmonk admin API.
# OIDC logins get the Super Admin role so every signed-in user can change settings.
# Usage: configure-instance.sh <project-id>
set -euo pipefail

# shellcheck source=api.sh
source "$(dirname "${BASH_SOURCE[0]}")/api.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: configure-instance.sh <project-id>" >&2
  exit 2
fi

ID="$1"
listmonk_load_instance "$ID"

ROOT_URL="$(listmonk_public_url "$ID")"
OIDC_ISSUER="${HABIDAT_PROTOCOL:-https}://${HABIDAT_USER_SUBDOMAIN}.${HABIDAT_DOMAIN}/oidc"

listmonk_wait_http "$ID"
../lib/wait-for.sh "listmonk $ID admin API" 180 \
  "docker run --rm --network 'container:$(listmonk_container "$ID")' \
     '$LISTMONK_CURL_IMAGE' -fsS -u '$(listmonk_api_user):$(listmonk_api_password)' \
     http://127.0.0.1:9000/api/settings"

echo "Using the Super Admin role for OIDC logins..."
roles_json="$(listmonk_api "$ID" GET /api/roles/users)"

role_id="$(ROLE_JSON="$roles_json" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["ROLE_JSON"])
roles = payload.get("data") or payload
if isinstance(roles, dict):
    roles = roles.get("results") or roles.get("data") or []
for role in roles:
    if role.get("name") == "Super Admin":
        print(role["id"])
        break
PY
)"

if [[ -z "$role_id" ]]; then
  echo "Listmonk Super Admin role was not found." >&2
  exit 1
fi

echo "Writing SMTP, OIDC and privacy settings (tracking off)..."
smtp_tls="${HABIDAT_SMTP_TLS:-false}"
smtp_port="${HABIDAT_SMTP_PORT:-1025}"
if [[ "$smtp_tls" == "true" && "$smtp_port" == "465" ]]; then
  tls_type="TLS"
elif [[ "$smtp_tls" == "true" ]]; then
  tls_type="STARTTLS"
else
  tls_type="none"
fi

settings_json="$(listmonk_api "$ID" GET /api/settings)"
merged="$(
  SITE_NAME="${HABIDAT_LISTMONK_TITLE}" \
  ROOT_URL="$ROOT_URL" \
  FROM_EMAIL="${HABIDAT_SMTP_EMAILFROM}" \
  SMTP_HOST="${HABIDAT_SMTP_HOST}" \
  SMTP_PORT="$smtp_port" \
  SMTP_USER="${HABIDAT_SMTP_USER:-}" \
  SMTP_PASSWORD="${HABIDAT_SMTP_PASSWORD:-}" \
  SMTP_AUTH="${HABIDAT_SMTP_AUTHMETHOD:-none}" \
  SMTP_TLS="$tls_type" \
  OIDC_ISSUER="$OIDC_ISSUER" \
  OIDC_CLIENT_ID="${HABIDAT_LISTMONK_OIDC_CLIENT_ID}" \
  OIDC_CLIENT_SECRET="${HABIDAT_LISTMONK_OIDC_CLIENT_SECRET}" \
  OIDC_ROLE_ID="$role_id" \
  python3 - "$settings_json" <<'PY'
import json, os, sys, uuid

def unmask(value):
    # GET /api/settings replaces secrets with the same number of bullets.
    # Writing those back stores the mask, and OIDC login then fails with
    # invalid_client. An empty secret tells Listmonk to keep the stored one.
    if isinstance(value, str) and value and set(value) <= {"•"}:
        return ""
    if isinstance(value, list):
        return [unmask(item) for item in value]
    if isinstance(value, dict):
        return {key: unmask(item) for key, item in value.items()}
    return value

payload = json.loads(sys.argv[1])
settings = payload.get("data") if isinstance(payload, dict) and "data" in payload else payload
settings = unmask(settings)

settings["app.site_name"] = os.environ["SITE_NAME"]
settings["app.root_url"] = os.environ["ROOT_URL"]
settings["app.from_email"] = os.environ["FROM_EMAIL"]
settings["privacy.disable_tracking"] = True
settings["privacy.individual_tracking"] = False

smtp = list(settings.get("smtp") or [])
entry = dict(smtp[0]) if smtp else {}
entry.update({
    "name": entry.get("name") or "habidat",
    "uuid": entry.get("uuid") or str(uuid.uuid4()),
    "enabled": True,
    "host": os.environ["SMTP_HOST"],
    "port": int(os.environ["SMTP_PORT"]),
    "auth_protocol": (os.environ.get("SMTP_AUTH") or "none").lower(),
    "username": os.environ.get("SMTP_USER") or "",
    "password": os.environ.get("SMTP_PASSWORD") or "",
    "hello_hostname": entry.get("hello_hostname") or "",
    "max_conns": int(entry.get("max_conns") or 10),
    "max_msg_retries": int(entry.get("max_msg_retries") or 2),
    "idle_timeout": entry.get("idle_timeout") or "15s",
    "wait_timeout": entry.get("wait_timeout") or "5s",
    "tls_type": os.environ["SMTP_TLS"],
    "tls_skip_verify": bool(entry.get("tls_skip_verify") or False),
    "email_headers": entry.get("email_headers") or [],
})
settings["smtp"] = [entry]

oidc = dict(settings.get("security.oidc") or {})
oidc.update({
    "enabled": True,
    "provider_url": os.environ["OIDC_ISSUER"],
    "provider_name": "habidat",
    "client_id": os.environ["OIDC_CLIENT_ID"],
    "client_secret": os.environ["OIDC_CLIENT_SECRET"],
    "auto_create_users": True,
    "default_user_role_id": int(os.environ["OIDC_ROLE_ID"]),
})
settings["security.oidc"] = oidc
json.dump(settings, sys.stdout)
PY
)"

printf '%s' "$merged" | listmonk_curl "$ID" \
  -sS -f \
  -u "$(listmonk_api_user):$(listmonk_api_password)" \
  -X PUT \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "http://127.0.0.1:9000/api/settings" >/dev/null

echo "Granting Super Admin to existing user accounts..."
users_json="$(listmonk_api "$ID" GET /api/users)"
promotions="$(
  USERS_JSON="$users_json" \
  ROLE_ID="$role_id" \
  python3 - <<'PY'
import json, os
payload = json.loads(os.environ["USERS_JSON"])
users = payload.get("data") or payload
if isinstance(users, dict):
    users = users.get("results") or users.get("data") or []
role_id = int(os.environ["ROLE_ID"])
for user in users:
    if user.get("type") != "user":
        continue
    current = (user.get("user_role") or {}).get("id")
    if current == role_id:
        continue
    body = {
        "username": user.get("username") or "",
        "name": user.get("name") or user.get("username") or "",
        "email": user.get("email") or "",
        "password_login": bool(user.get("password_login")),
        "status": user.get("status") or "enabled",
        "user_role_id": role_id,
    }
    print(f"{user['id']}\t{json.dumps(body)}")
PY
)"
while IFS= read -r promotion; do
  [[ -n "$promotion" ]] || continue
  user_id="${promotion%%$'\t'*}"
  body="${promotion#*$'\t'}"
  listmonk_api "$ID" PUT "/api/users/${user_id}" --data "$body" >/dev/null
done <<< "$promotions"

echo "Restarting listmonk so OIDC routes are registered..."
docker compose -f "$(listmonk_compose "$ID")" -p "$(listmonk_project "$ID")" restart listmonk
listmonk_wait_http "$ID"

# --install seeds a public "Opt-in list", a private "Default list", two sample
# subscribers and a "Test campaign". Drop them so a fresh instance is empty.
# The public subscription page setting is left as Listmonk ships it.
echo "Removing Listmonk sample campaign, subscribers and lists..."
campaigns_json="$(listmonk_api "$ID" GET "/api/campaigns?page=1&per_page=50")"
lists_json="$(listmonk_api "$ID" GET "/api/lists?page=1&per_page=50")"
sub_query="$(python3 -c 'import urllib.parse; print(urllib.parse.quote("subscribers.email IN ('"'"'john@example.com'"'"', '"'"'anon@example.com'"'"')"))')"
subs_json="$(listmonk_api "$ID" GET "/api/subscribers?page=1&per_page=50&query=${sub_query}")"
SAMPLE_IDS="$(
  CAMPAIGNS_JSON="$campaigns_json" \
  LISTS_JSON="$lists_json" \
  SUBS_JSON="$subs_json" \
  python3 - <<'PY'
import json, os

def results(raw):
    payload = json.loads(raw) if raw else {}
    data = payload.get("data", payload)
    if isinstance(data, dict):
        return data.get("results") or []
    return data or []

for item in results(os.environ["CAMPAIGNS_JSON"]):
    if item.get("name") == "Test campaign":
        print(f"campaign {item['id']}")
for item in results(os.environ["SUBS_JSON"]):
    if (item.get("email") or "").lower() in {"john@example.com", "anon@example.com"}:
        print(f"subscriber {item['id']}")
for item in results(os.environ["LISTS_JSON"]):
    if item.get("name") in {"Default list", "Opt-in list"}:
        print(f"list {item['id']}")
PY
)"
while IFS= read -r sample_line; do
  [[ -n "$sample_line" ]] || continue
  kind="${sample_line%% *}"
  sample_id="${sample_line##* }"
  case "$kind" in
    campaign) listmonk_api "$ID" DELETE "/api/campaigns/${sample_id}" >/dev/null ;;
    subscriber) listmonk_api "$ID" DELETE "/api/subscribers/${sample_id}" >/dev/null ;;
    list) listmonk_api "$ID" DELETE "/api/lists/${sample_id}" >/dev/null ;;
  esac
done <<< "$SAMPLE_IDS"

# Install seeds "Sample visual template". Replace that document so the visual
# editor's import list starts from the habidat layout. Do not call
# /api/templates/:id/default: that flag only applies to HTML campaign templates,
# and the call clears the current default.
echo "Installing the standard visual campaign template..."
template_file="$(dirname "${BASH_SOURCE[0]}")/../assets/standard-visual-template.json"
templates_json="$(listmonk_api "$ID" GET "/api/templates")"
template_work="$(mktemp -d)"
trap 'rm -rf "$template_work"' EXIT
existing_id="$(
  TEMPLATES_JSON="$templates_json" \
  TEMPLATE_FILE="$template_file" \
  PAYLOAD_FILE="$template_work/payload.json" \
  python3 - <<'PY'
import json, os

asset = json.load(open(os.environ["TEMPLATE_FILE"], encoding="utf-8"))
payload = json.loads(os.environ["TEMPLATES_JSON"])
data = payload.get("data", payload)
if isinstance(data, dict):
    data = data.get("results") or []
by_name = {
    item.get("name"): item
    for item in data
    if item.get("type") == asset["type"]
}
current = by_name.get(asset["name"]) or by_name.get("Sample visual template")
json.dump(
    {
        "name": asset["name"],
        "type": asset["type"],
        "body": asset["body"],
        "body_source": asset["body_source"],
    },
    open(os.environ["PAYLOAD_FILE"], "w", encoding="utf-8"),
    ensure_ascii=False,
)
print(current["id"] if current else "")
PY
)"
if [[ -n "$existing_id" ]]; then
  listmonk_api "$ID" PUT "/api/templates/${existing_id}" --data-binary @- \
    < "$template_work/payload.json" >/dev/null
else
  listmonk_api "$ID" POST "/api/templates" --data-binary @- \
    < "$template_work/payload.json" >/dev/null
fi
rm -rf "$template_work"

echo "Listmonk settings applied."
