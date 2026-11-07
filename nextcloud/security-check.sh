#!/usr/bin/env bash
set -euo pipefail

# Module part of `habidat.sh security-check` (see docs/plans/security-check.md,
# "Module hook contract"). Read-only. Prints one tab-separated record per line:
#
#   volume   <container> <path>                         scanned with Syft/Grype
#   finding  <type> <subject> <severity> <title> <fix>
#   skip     <reason>

CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud"

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
  printf 'skip\t%s is not running\n' "$CONTAINER"
  exit 0
fi

occ() {
  docker exec --user www-data "$CONTAINER" php occ "$@"
}

# Apps from the app store live in the data volume, not in the image.
printf 'volume\t%s\t%s\n' "$CONTAINER" /var/www/html/custom_apps

# Server and app updates (contacts updates.nextcloud.com / the app store).
if updates="$(occ update:check 2>&1)"; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^Update\ for\ ([^ ]+)\ to\ version\ ([^ ]+)\ is\ available ]]; then
      printf 'finding\toutdated-app\t%s\tMEDIUM\tNextcloud app %s %s is available\t%s\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
        "docker exec --user www-data $CONTAINER php occ app:update ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^(Nextcloud\ [0-9][^ ]*)\ is\ available ]]; then
      printf 'finding\tnextcloud-update\tserver\tMEDIUM\t%s is available\t%s\n' \
        "${BASH_REMATCH[1]}" "./habidat.sh update nextcloud (once habidat ships it)"
    fi
  done <<< "$updates"
else
  printf 'skip\tocc update:check failed: %s\n' "$(tail -n1 <<< "$updates")"
fi

# The warnings of Nextcloud's own administration overview (Nextcloud 28+).
if checks="$(occ setupchecks --output=json 2>/dev/null)"; then
  python3 -I -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except ValueError:
    sys.exit(0)
for category, items in (data or {}).items():
    for key, item in (items or {}).items():
        if not isinstance(item, dict) or item.get("severity") not in ("warning", "error"):
            continue
        name = " ".join(str(item.get("name") or key).split())
        desc = " ".join(str(item.get("description") or "").split())
        title = name + (": " + desc[:160] if desc else "")
        print("finding\tnextcloud-setup\t%s\tMEDIUM\t%s\t%s" % (
            key.replace("\t", " "), title.replace("\t", " "),
            "see Administration settings > Overview in Nextcloud"))
' "$checks"
else
  printf 'skip\tocc setupchecks not available\n'
fi
