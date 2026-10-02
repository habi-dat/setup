#!/usr/bin/env bash
# Local mkcert certificate names. Sourced, not executed.
# *.domain matches one label (cloud.domain, user.domain). Project instances
# live at project.lists.domain, which needs its own wildcard.

habidat_selfsigned_hostnames() {
  local domain="${1:-${HABIDAT_DOMAIN:?HABIDAT_DOMAIN is required}}"
  printf '%s\n' "*.${domain}"
  local sub
  for sub in \
    "${HABIDAT_LISTMONK_SUBDOMAIN:-lists}" \
    "${HABIDAT_MEDIAWIKI_SUBDOMAIN:-mediawiki}" \
    "${HABIDAT_MAILTRAIN_SUBDOMAIN:-mailtrain}"
  do
    [[ -z "$sub" || "$sub" == *.* ]] && continue
    printf '%s\n' "*.${sub}.${domain}"
  done
}

habidat_cert_has_dns() {
  local cert="$1"
  local name="$2"
  python3 - "$cert" "$name" <<'PY'
import subprocess, sys
cert, name = sys.argv[1], sys.argv[2]
out = subprocess.check_output(
    ["openssl", "x509", "-in", cert, "-noout", "-ext", "subjectAltName"],
    text=True,
)
names = set()
for part in out.replace("\n", " ").split(","):
    part = part.strip()
    if "DNS:" in part:
        names.add(part.split("DNS:", 1)[1].strip())
sys.exit(0 if name in names else 1)
PY
}

habidat_ensure_selfsigned_cert() {
  [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]] || return 0
  local domain="${HABIDAT_DOMAIN:?HABIDAT_DOMAIN is required}"
  local root cert_dir cert name missing
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cert_dir="${root}/store/nginx/certificates"
  [[ -d "$cert_dir" ]] || return 0
  cert="${cert_dir}/${domain}.crt"
  missing=0
  if [[ ! -f "$cert" ]]; then
    missing=1
  else
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! habidat_cert_has_dns "$cert" "$name"; then
        missing=1
        break
      fi
    done < <(habidat_selfsigned_hostnames "$domain")
  fi
  [[ "$missing" -eq 1 ]] || return 0
  echo "Generating self-signed certificate for ${domain}..."
  local -a args=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    args+=("$name")
  done < <(habidat_selfsigned_hostnames "$domain")
  mkcert -install \
    -key-file "${cert_dir}/${domain}.key" \
    -cert-file "$cert" \
    "${args[@]}"
}
