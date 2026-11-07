#!/usr/bin/env bash
# `habidat.sh security-check` -- read-only security check of the server and
# the containers on it. See docs/plans/security-check.md and the "Security"
# section of GLOSSARY.md.
#
# This file collects raw data (docker inspect, Syft/Grype output, host tool
# output, TLS probes, module hook output) into a report directory; the rules
# that turn it into findings live in lib/security/analyse.py.
#
# Sourced by habidat.sh -- do not execute directly.

# shellcheck source=lib/security/scanners.sh
source "$BASE_DIR/lib/security/scanners.sh"

SECURITY_DIR_NAME=".security-check"

_security_usage() {
  log_info "Usage: habidat.sh [--verbose] [--dry-run] security-check [all | <module> [<instance>]]"
  log_info "         [--all-images] [--host-audit] [--tls-full] [--severity LOW|MEDIUM|HIGH|CRITICAL]"
  log_info ""
  log_info "Read-only. Exit codes: 0 nothing to act on, 1 an urgent vulnerability or another finding at/above"
  log_info "the severity, 2 a check could not run. Vulnerabilities are urgent when known or likely to be exploited."
  log_info "Run with sudo for the host checks that need root."
}

# _security_record <name> <ok|skipped|failed> [note]
_security_record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$SEC_RAW/checks.tsv"
}

_security_python() {
  python3 -I "$BASE_DIR/lib/security/analyse.py" "$@"
}

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
_security_collect_inventory() {
  local -a ids=() image_ids=()
  mapfile -t ids < <(docker ps -q --no-trunc 2>/dev/null)
  if [[ ${#ids[@]} -gt 0 ]]; then
    docker inspect "${ids[@]}" > "$SEC_RAW/containers.json"
    mapfile -t image_ids < <(docker inspect --format '{{.Image}}' "${ids[@]}" | sort -u)
  else
    echo "[]" > "$SEC_RAW/containers.json"
  fi
  if [[ "$SEC_ALL_IMAGES" == "true" && -z "$SEC_TARGET" ]]; then
    mapfile -t image_ids < <({ printf '%s\n' "${image_ids[@]+"${image_ids[@]}"}"; docker image ls -q --no-trunc; } | sed '/^$/d' | sort -u)
  fi
  if [[ ${#image_ids[@]} -gt 0 ]]; then
    docker image inspect "${image_ids[@]}" > "$SEC_RAW/images.json"
  else
    echo "[]" > "$SEC_RAW/images.json"
  fi

  local mod instances dir
  : > "$SEC_RAW/installed.tsv"
  for mod in $(get_ordered_modules); do
    is_installed "$mod" || continue
    instances=""
    if is_multi_instance "$mod"; then
      for dir in "$BASE_DIR/store/$mod"/*/; do
        [[ -d "$dir" ]] && instances+="${instances:+,}$(basename "$dir")"
      done
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$mod" "$(get_installed_version "$mod")" \
      "$(get_target_version "$mod")" "$(is_multi_instance "$mod" && echo 1 || echo 0)" "$instances" \
      >> "$SEC_RAW/installed.tsv"
  done

  local -a inv_args=(inventory --raw "$SEC_RAW" --prefix "$HABIDAT_DOCKER_PREFIX")
  [[ -n "$SEC_TARGET" ]] && inv_args+=(--target "$SEC_TARGET")
  [[ -n "$SEC_INSTANCE" ]] && inv_args+=(--instance "$SEC_INSTANCE")
  [[ "$SEC_ALL_IMAGES" == "true" ]] && inv_args+=(--all-images)

  SEC_IMAGES=() SEC_VHOSTS=() SEC_CONTAINERS=()
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      image)     SEC_IMAGES+=("$a"$'\t'"$b"$'\t'"$c") ;;
      vhost)     SEC_VHOSTS+=("$a") ;;
      container) SEC_CONTAINERS+=("$a"$'\t'"$b") ;;
    esac
  done < <(_security_python "${inv_args[@]}")
}

# ---------------------------------------------------------------------------
# Images: Syft SBOM (cached per image ID and Syft version) + Grype
# ---------------------------------------------------------------------------
_security_scan_images() {
  local syft_version="${SECURITY_SYFT_IMAGE#*:}"
  syft_version="${syft_version%%@*}"
  local sbom_cache="$SEC_CACHE/sbom/$syft_version"
  mkdir -p "$sbom_cache" "$SEC_REPORT/sbom" "$SEC_REPORT/grype"

  local total=${#SEC_IMAGES[@]} n=0 entry id slug label sbom
  for entry in "${SEC_IMAGES[@]+"${SEC_IMAGES[@]}"}"; do
    IFS=$'\t' read -r id slug label <<< "$entry"
    n=$((n + 1))
    sbom="$SEC_REPORT/sbom/$slug.syft.json"
    if [[ -s "$sbom_cache/${id#sha256:}.json" ]]; then
      log_info "[$n/$total] $label: SBOM from cache, matching vulnerabilities..."
      cp "$sbom_cache/${id#sha256:}.json" "$sbom"
    else
      log_info "[$n/$total] $label: building SBOM..."
      if ! security_syft_image "$id" "$sbom" 2> "$SEC_RAW/syft-$slug.err" || [[ ! -s "$sbom" ]]; then
        _security_record "images.sbom:$label" failed "Syft failed: $(tail -n1 "$SEC_RAW/syft-$slug.err")"
        rm -f "$sbom"
        continue
      fi
      cp "$sbom" "$sbom_cache/${id#sha256:}.json"
      log_info "[$n/$total] $label: matching vulnerabilities..."
    fi
    if ! security_grype "$sbom" "$SEC_REPORT/grype/$slug.json" 2> "$SEC_RAW/grype-$slug.err" \
      || [[ ! -s "$SEC_REPORT/grype/$slug.json" ]]; then
      _security_record "images.vulnerabilities:$label" failed "Grype failed: $(tail -n1 "$SEC_RAW/grype-$slug.err")"
      rm -f "$SEC_REPORT/grype/$slug.json"
    fi
  done
}

# ---------------------------------------------------------------------------
# Module hooks: <module>/security-check.sh [<instance>]
# ---------------------------------------------------------------------------
_security_run_hooks() {
  mkdir -p "$SEC_RAW/hooks"
  : > "$SEC_RAW/volumes.tsv"
  local mod instance scope file rc line container path slug n=0
  local -a instances
  while IFS=$'\t' read -r mod _ _ _ instance_list; do
    [[ -n "$SEC_TARGET" && "$mod" != "$SEC_TARGET" ]] && continue
    [[ -x "$BASE_DIR/$mod/security-check.sh" ]] || continue
    instances=("")
    if [[ -n "$instance_list" ]]; then
      IFS=',' read -r -a instances <<< "$instance_list"
    fi
    for instance in "${instances[@]}"; do
      [[ -n "$SEC_INSTANCE" && "$instance" != "$SEC_INSTANCE" ]] && continue
      scope="$mod${instance:+/$instance}"
      file="$SEC_RAW/hooks/$mod${instance:+__$instance}.tsv"
      log_info "$scope: running module checks..."
      rc=0
      (cd "$BASE_DIR/$mod" && ./security-check.sh ${instance:+"$instance"}) \
        > "$file" 2> "${file%.tsv}.log" || rc=$?
      if [[ $rc -ne 0 ]]; then
        _security_record "hook:$scope" failed "security-check.sh exited $rc: $(tail -n1 "${file%.tsv}.log")"
      fi
      while IFS=$'\t' read -r line container path; do
        [[ "$line" == "volume" && -n "$container" && -n "$path" ]] || continue
        n=$((n + 1))
        slug="vol-${mod}${instance:+-$instance}-$n"
        log_info "$scope: scanning $path in $container..."
        if security_syft_dir "$container" "$path" "$SEC_REPORT/sbom/$slug.syft.json" 2> "$SEC_RAW/syft-$slug.err" \
          && security_grype "$SEC_REPORT/sbom/$slug.syft.json" "$SEC_REPORT/grype/$slug.json" 2> "$SEC_RAW/grype-$slug.err"; then
          printf '%s\t%s\t%s\t%s\n' "$scope" "$container" "$path" "$slug" >> "$SEC_RAW/volumes.tsv"
        else
          _security_record "volume:$scope:$path" failed "scan of $path in $container failed"
        fi
      done < "$file"
    done
  done < "$SEC_RAW/installed.tsv"
}

# ---------------------------------------------------------------------------
# Host (Debian / Ubuntu)
# ---------------------------------------------------------------------------
_security_collect_host() {
  local host="$SEC_RAW/host"
  mkdir -p "$host"
  cp /etc/os-release "$host/os-release" 2>/dev/null || true
  local os_id
  # shellcheck disable=SC1091
  os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"

  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn > "$host/ss.txt" 2>/dev/null || true
  else
    _security_record host.listening skipped "ss not found (apt install iproute2)"
  fi
  [[ -r /etc/ufw/ufw.conf ]] && cp /etc/ufw/ufw.conf "$host/ufw.conf"

  local os_like
  # shellcheck disable=SC1091
  os_like="$(. /etc/os-release 2>/dev/null; echo "$ID ${ID_LIKE:-}")"
  if [[ ! " $os_like " =~ \ (debian|ubuntu)\  ]]; then
    _security_record host.packages skipped "unsupported OS '$os_id' (Debian, Ubuntu and their derivatives only)"
    return 0
  fi

  log_info "host: checking packages..."
  if apt-get -s -o Debug::NoLocking=1 dist-upgrade > "$host/apt-sim.txt" 2> "$SEC_RAW/apt.err"; then
    _security_record host.updates ok
  else
    _security_record host.updates failed "apt-get -s dist-upgrade failed: $(tail -n1 "$SEC_RAW/apt.err")"
  fi
  local newest
  newest="$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -n | tail -n1)"
  if [[ -n "$newest" ]]; then
    echo $(( ($(date +%s) - ${newest%.*}) / 86400 )) > "$host/apt-lists-age"
  fi

  if [[ "$os_id" == "debian" ]]; then
    if command -v check-support-status >/dev/null 2>&1; then
      check-support-status > "$host/support-status.txt" 2>/dev/null || true
      _security_record host.support-status ok
    else
      _security_record host.support-status skipped "apt install debian-security-support"
    fi
  fi

  if ! command -v needrestart >/dev/null 2>&1; then
    _security_record host.needrestart skipped "apt install needrestart"
  elif [[ $EUID -ne 0 ]]; then
    _security_record host.needrestart skipped "re-run with sudo"
  else
    needrestart -b > "$host/needrestart.txt" 2>/dev/null || true
    _security_record host.needrestart ok
  fi

  local installed=no enabled=0
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
    installed=yes
  fi
  enabled="$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | sed -nE 's/.*"([0-9]+)".*/\1/p' | tail -n1)"
  printf 'installed=%s\nenabled=%s\n' "$installed" "${enabled:-0}" > "$host/unattended.txt"

  if [[ "$SEC_HOST_AUDIT" == "true" ]]; then
    if command -v lynis >/dev/null 2>&1; then
      log_info "host: running Lynis (takes a few minutes)..."
      lynis audit system --quick --no-colors \
        --report-file "$host/lynis-report.dat" --logfile "$host/lynis.log" > "$host/lynis.out" 2>&1 || true
      if [[ -s "$host/lynis-report.dat" ]]; then
        _security_record host.lynis ok "$([[ $EUID -ne 0 ]] && echo "ran without root, fewer tests")"
      else
        _security_record host.lynis failed "Lynis wrote no report (see raw/host/lynis.out)"
      fi
    else
      _security_record host.lynis skipped "apt install lynis"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Docker daemon
# ---------------------------------------------------------------------------
_security_collect_docker() {
  mkdir -p "$SEC_RAW/docker"
  docker info --format '{{json .}}' > "$SEC_RAW/docker/info.json" 2>/dev/null || true
  docker network inspect bridge > "$SEC_RAW/docker/bridge.json" 2>/dev/null || true
  if [[ -r /etc/docker/daemon.json ]]; then
    cp /etc/docker/daemon.json "$SEC_RAW/docker/daemon.json"
  elif [[ -e /etc/docker/daemon.json ]]; then
    _security_record docker.daemon-config skipped "/etc/docker/daemon.json not readable, re-run with sudo"
  fi
}

# ---------------------------------------------------------------------------
# TLS: certificate of every module host name, testssl.sh on the main one
# ---------------------------------------------------------------------------
_security_is_public_domain() {
  case "${HABIDAT_DOMAIN:-}" in
    ""|localhost|*.localhost|*.test|*.local|*.example|*.invalid) return 1 ;;
  esac
  return 0
}

_security_collect_tls() {
  if ! _security_is_public_domain; then
    _security_record tls skipped "not a public domain ($HABIDAT_DOMAIN)"
    return 0
  fi
  if [[ ${#SEC_VHOSTS[@]} -eq 0 ]]; then
    _security_record tls skipped "no module host names found"
    return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    _security_record tls.cert skipped "openssl not found"
  fi
  local tls="$SEC_RAW/tls" host out pem
  mkdir -p "$tls"
  for host in "${SEC_VHOSTS[@]}"; do
    command -v openssl >/dev/null 2>&1 || break
    out="$(timeout 20 openssl s_client -connect 127.0.0.1:443 -servername "$host" </dev/null 2>/dev/null || true)"
    pem="$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' <<< "$out")"
    if [[ -z "$pem" ]]; then
      echo "connect=failed" > "$tls/$host.cert"
      continue
    fi
    {
      echo "connect=ok"
      echo "verify=$(sed -n 's/^ *Verify return code: //p' <<< "$out" | tail -n1)"
      echo "notafter=$(openssl x509 -noout -enddate <<< "$pem" | cut -d= -f2-)"
      echo "subject=$(openssl x509 -noout -subject <<< "$pem" | cut -d= -f2-)"
      if openssl x509 -noout -checkhost "$host" <<< "$pem" 2>/dev/null | grep -q "does match"; then
        echo "hostmatch=yes"
      else
        echo "hostmatch=no"
      fi
    } > "$tls/$host.cert"
  done

  local -a targets=()
  if [[ "$SEC_TLS_FULL" == "true" ]]; then
    targets=("${SEC_VHOSTS[@]}")
  else
    local main="${HABIDAT_USER_SUBDOMAIN:-user}.$HABIDAT_DOMAIN"
    targets=("${SEC_VHOSTS[0]}")
    for host in "${SEC_VHOSTS[@]}"; do
      if [[ "$host" == "$main" ]]; then targets=("$host"); fi
    done
  fi
  for host in "${targets[@]}"; do
    log_info "tls: running testssl.sh against $host (1-2 minutes)..."
    security_testssl "$host" "$tls" || true
    if [[ ! -s "$tls/testssl-$host.json" ]]; then
      _security_record "tls.testssl:$host" failed "testssl.sh wrote no result (see raw/tls/testssl-$host.log)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
security_check() {
  SEC_TARGET="" SEC_INSTANCE="" SEC_ALL_IMAGES=false SEC_HOST_AUDIT=false SEC_TLS_FULL=false
  local severity="HIGH" sec_verbose="$VERBOSE"
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all-images) SEC_ALL_IMAGES=true ;;
      --host-audit) SEC_HOST_AUDIT=true ;;
      --tls-full)   SEC_TLS_FULL=true ;;
      --verbose)    sec_verbose=true ;;
      --severity)
        shift
        severity="$(upper "${1:-}")"
        [[ "$severity" =~ ^(LOW|MEDIUM|HIGH|CRITICAL)$ ]] || die "--severity needs LOW, MEDIUM, HIGH or CRITICAL"
        ;;
      --severity=*)
        severity="$(upper "${1#*=}")"
        [[ "$severity" =~ ^(LOW|MEDIUM|HIGH|CRITICAL)$ ]] || die "--severity needs LOW, MEDIUM, HIGH or CRITICAL"
        ;;
      -h|--help) _security_usage; return 0 ;;
      --*) _security_usage; die "Unknown security-check option: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  if [[ ${#positional[@]} -gt 0 && "${positional[0]}" != "all" ]]; then
    SEC_TARGET="${positional[0]}"
    is_valid_module "$SEC_TARGET" || die "Unknown module: $SEC_TARGET"
    is_installed "$SEC_TARGET" || die "Module $SEC_TARGET is not installed"
    if [[ ${#positional[@]} -gt 1 ]]; then
      SEC_INSTANCE="${positional[1]}"
      is_multi_instance "$SEC_TARGET" || die "Module $SEC_TARGET has no instances"
      [[ -d "$BASE_DIR/store/$SEC_TARGET/$SEC_INSTANCE" ]] || die "Unknown $SEC_TARGET instance: $SEC_INSTANCE"
    fi
  fi
  [[ ${#positional[@]} -gt 2 ]] && die "Too many arguments: ${positional[*]}"

  local state="$BASE_DIR/store/$SECURITY_DIR_NAME"
  SEC_CACHE="$state/cache"
  if [[ "$DRY_RUN" == "true" ]]; then
    SEC_REPORT="$(mktemp -d)"
    register_cleanup "rm -rf '$SEC_REPORT'"
  else
    SEC_REPORT="$state/reports/$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  SEC_RAW="$SEC_REPORT/raw"
  mkdir -p "$SEC_RAW"
  : > "$SEC_RAW/checks.tsv"
  local started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log_info "Security check of ${SEC_TARGET:-the whole server}${SEC_INSTANCE:+ (instance $SEC_INSTANCE)} -- read-only."
  [[ $EUID -ne 0 && -z "$SEC_TARGET" ]] && log_info "Not running as root: some host checks will be skipped (re-run with sudo for all)."

  _security_collect_inventory

  if [[ "$DRY_RUN" == "true" ]]; then
    local entry
    log_info "[dry-run] images to scan with $SECURITY_SYFT_IMAGE and $SECURITY_GRYPE_IMAGE:"
    for entry in "${SEC_IMAGES[@]+"${SEC_IMAGES[@]}"}"; do
      log_info "[dry-run]   $(cut -f3 <<< "$entry")"
    done
    log_info "[dry-run] containers:"
    for entry in "${SEC_CONTAINERS[@]+"${SEC_CONTAINERS[@]}"}"; do
      log_info "[dry-run]   $(cut -f1 <<< "$entry") ($(cut -f2 <<< "$entry"))"
    done
    local mod
    while IFS=$'\t' read -r mod _; do
      [[ -n "$SEC_TARGET" && "$mod" != "$SEC_TARGET" ]] && continue
      if [[ -x "$BASE_DIR/$mod/security-check.sh" ]]; then
        log_info "[dry-run] module checks: $mod/security-check.sh"
      fi
    done < "$SEC_RAW/installed.tsv"
    if [[ -z "$SEC_TARGET" ]]; then
      log_info "[dry-run] host checks, Docker daemon checks, exposure checks"
      if _security_is_public_domain && [[ ${#SEC_VHOSTS[@]} -gt 0 ]]; then
        log_info "[dry-run] TLS: certificates of ${SEC_VHOSTS[*]}; testssl.sh with $SECURITY_TESTSSL_IMAGE"
      fi
    fi
    return 0
  fi

  mkdir -p "$SEC_CACHE"
  printf '{"syft": "%s", "grype": "%s", "testssl": "%s"}\n' \
    "$SECURITY_SYFT_IMAGE" "$SECURITY_GRYPE_IMAGE" "$SECURITY_TESTSSL_IMAGE" > "$SEC_RAW/scanners.json"

  _security_scan_images
  _security_run_hooks
  if [[ -z "$SEC_TARGET" ]]; then
    _security_collect_host
    _security_collect_docker
    _security_collect_tls
  fi

  local -a ana_args=(analyse --report "$SEC_REPORT" --cache "$SEC_CACHE"
    --accepted "$state/accepted" --data "$BASE_DIR/lib/security/data" --base "$BASE_DIR"
    --severity "$severity" --started "$started")
  [[ -n "$SEC_TARGET" ]] && ana_args+=(--target "$SEC_TARGET${SEC_INSTANCE:+/$SEC_INSTANCE}" --module-only)
  [[ "$SEC_ALL_IMAGES" == "true" ]] && ana_args+=(--all-images)
  [[ "$SEC_HOST_AUDIT" == "true" ]] && ana_args+=(--host-audit)
  [[ "$SEC_TLS_FULL" == "true" ]] && ana_args+=(--tls-full)
  [[ "$sec_verbose" == "true" ]] && ana_args+=(--verbose)
  [[ -t 1 && -n "$_RESET" ]] && ana_args+=(--color)

  local rc=0 prefix
  prefix="$(_log_prefix "SECURITY" "$_MAGENTA")"
  _security_python "${ana_args[@]}" > "$SEC_RAW/analyse.out" 2> "$SEC_RAW/analyse.err" || rc=$?
  sed "s/^/$prefix/" "$SEC_RAW/analyse.out"
  if [[ $rc -ne 0 && $rc -ne 1 && $rc -ne 2 ]] || [[ ! -s "$SEC_REPORT/report.json" ]]; then
    cat "$SEC_RAW/analyse.err" >&2
    log_error "The analysis failed (exit $rc)."
    rc=2
  fi

  find "$SEC_RAW" -maxdepth 1 -type f -empty -delete 2>/dev/null || true
  ln -sfn "$(basename "$SEC_REPORT")" "$state/reports/latest"
  if [[ $EUID -eq 0 ]]; then
    chown -R --reference="$BASE_DIR/store" "$state" 2>/dev/null || true
  fi
  return "$rc"
}
