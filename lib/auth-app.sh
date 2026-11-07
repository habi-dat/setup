#!/usr/bin/env bash
# Link-step helper: puts a module's login app into habidat-auth.
# Sourced by <module>/link.sh -- do not execute directly.
#
# auth_app_link <app-json-file>
#
#   <app-json-file> is the module's file in store/auth/user-import/ (the format
#   auth's seed imports: a list of {id, label, url, oidc|saml, groups}). For
#   every app in it:
#
#   - an app that is missing from the auth database is created with the file's
#     name, URL, login settings and install-time groups;
#   - an app that exists only gets its login settings updated -- OIDC client ID,
#     secret and redirect URIs, or the SAML entity ID and endpoints -- because
#     those must match the module's own files. Name, URL and groups are left as
#     an admin may have changed them (ADR 0007).
#
#   It deliberately does not run auth's user-init, whose seed re-attaches
#   install-time groups to apps that already exist.
#
#   Needs auth's user-db container to be running. Paths are relative to the
#   module directory, like every other module script.

auth_app_sql() {
  python3 - "$1" <<'PY'
import json, sys

def q(value):
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"

apps = json.load(open(sys.argv[1]))
if isinstance(apps, dict):
    apps = [apps]

for app in apps:
    slug = app["id"]
    cols, vals, sets = [], [], []

    oidc = app.get("oidc") or {}
    if oidc.get("enabled"):
        fields = {
            '"oidcEnabled"': "true",
            '"oidcClientId"': q(oidc.get("clientId")),
            '"oidcClientSecret"': q(oidc.get("clientSecret")),
            '"oidcRedirectUris"': q(json.dumps(oidc.get("redirectUris") or [])),
        }
    else:
        fields = {}
    saml = app.get("saml") or {}
    if saml.get("samlEnabled"):
        fields.update({
            '"samlEnabled"': "true",
            '"samlEntityId"': q(saml.get("entityId")),
            '"samlAcsUrl"': q(saml.get("acs")),
            '"samlSloUrl"': q(saml.get("slo")),
        })
    for col, val in fields.items():
        cols.append(col)
        vals.append(val)
        sets.append(f"{col} = {val}")

    groups = [str(g).lower() for g in app.get("groups") or []]
    group_array = "ARRAY[" + ", ".join(q(g) for g in groups) + "]::text[]"
    update_set = ", ".join(sets) if sets else '"updatedAt" = "updatedAt"'
    extra_cols = "".join(", " + c for c in cols)
    extra_vals = "".join(", " + v for v in vals)

    print(f"""
WITH updated AS (
  UPDATE "App" SET {update_set}
  WHERE slug = {q(slug)}
  RETURNING id
),
inserted AS (
  INSERT INTO "App" ("id", slug, name, url, "updatedAt"{extra_cols})
  SELECT gen_random_uuid()::text, {q(slug)}, {q(app.get("label") or slug)}, {q(app.get("url") or "")}, CURRENT_TIMESTAMP{extra_vals}
  WHERE NOT EXISTS (SELECT 1 FROM updated)
  RETURNING id
),
granted AS (
  INSERT INTO "AppGroupAccess" ("id", "appId", "groupId")
  SELECT gen_random_uuid()::text, i.id, g.id
  FROM inserted i
  JOIN "Group" g
    ON lower(g.slug) = ANY({group_array})
    OR lower(coalesce(g."ldapDn", '')) = ANY({group_array})
  ON CONFLICT ("appId", "groupId") DO NOTHING
  RETURNING 1
)
SELECT CASE WHEN EXISTS (SELECT 1 FROM inserted) THEN 'inserted' ELSE 'updated' END
       || '|' || {q(slug)} || '|' || (SELECT count(*) FROM granted);""")
PY
}

auth_app_link() {
  local file="$1"
  local auth_compose="../store/auth/docker-compose.yml"

  if [[ ! -f "$file" ]]; then
    echo "auth_app_link: $file not found." >&2
    return 1
  fi
  if [[ ! -f "$auth_compose" ]]; then
    echo "auth is not installed; skipping its login app."
    return 0
  fi

  local sql result line slug granted
  sql="$(auth_app_sql "$file")" || return 1
  result="$(docker compose -f "$auth_compose" -p "$HABIDAT_DOCKER_PREFIX-auth" \
    exec -T user-db psql -U postgres -d habidat_auth -v ON_ERROR_STOP=1 -tA <<< "$sql")" || {
    echo "Could not write the login app from $file to the auth database." >&2
    return 1
  }

  while IFS='|' read -r line slug granted; do
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    case "$line" in
      inserted) echo "Created auth app ${slug} (${granted//[[:space:]]/} group(s))." ;;
      updated) echo "Updated login settings of auth app ${slug}." ;;
    esac
  done <<< "${result//$'\r'/}"
}
