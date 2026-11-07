#!/usr/bin/env bash
# Pinned scanner images for `habidat.sh security-check` and helpers to run them.
# Sourced by lib/security.sh -- do not execute directly.
#
# Every image is pinned by version AND digest (see docs/adr/0009). Updating a
# scanner is a deliberate change here; a static test rejects unpinned images.
# Resolve a new digest with:
#   docker buildx imagetools inspect <image>:<tag> --format '{{json .Manifest.Digest}}'

SECURITY_SYFT_IMAGE="anchore/syft:v1.57.0@sha256:3c70e6d5979364cefdc22b51617a78fd264574d3bd6b4f84a351204147025e2a"
SECURITY_GRYPE_IMAGE="anchore/grype:v0.121.2@sha256:6a36234da13f9faa327306ac0b3dab3405cfa2b4eb20c8f904125a8707863913"
# testssl.sh 3.2.5; the project publishes only the rolling 3.2 tag, the digest pins it.
SECURITY_TESTSSL_IMAGE="ghcr.io/testssl/testssl.sh:3.2@sha256:53766ec224a2d841b5516bc3923a8586379069ad01c65bbae9244aa24d72a18d"

# Socket the Syft container reads local images through.
security_docker_socket() {
  local host="${DOCKER_HOST:-unix:///var/run/docker.sock}"
  if [[ "$host" == unix://* ]]; then
    echo "${host#unix://}"
  else
    echo "/var/run/docker.sock"
  fi
}

security_grype_db_volume() {
  echo "${HABIDAT_DOCKER_PREFIX}-security-check-grype-db"
}

# security_syft_image <image-id> <out-file>
security_syft_image() {
  local sock
  sock="$(security_docker_socket)"
  docker run --rm -v "$sock:/var/run/docker.sock:ro" \
    "$SECURITY_SYFT_IMAGE" "docker:$1" -o syft-json -q > "$2"
}

# security_syft_dir <container> <path-in-container> <out-file>
#   Scans a directory that lives in one of the container's volumes.
security_syft_dir() {
  docker run --rm --volumes-from "$1:ro" \
    "$SECURITY_SYFT_IMAGE" "dir:$2" -o syft-json -q > "$3"
}

# security_grype <sbom-file> <out-file>
security_grype() {
  local dir file
  dir="$(cd "$(dirname "$1")" && pwd)"
  file="$(basename "$1")"
  docker run --rm \
    -e GRYPE_DB_CACHE_DIR=/grype-db \
    -e GRYPE_CHECK_FOR_APP_UPDATE=false \
    -v "$(security_grype_db_volume):/grype-db" \
    -v "$dir:/sbom:ro" \
    "$SECURITY_GRYPE_IMAGE" "sbom:/sbom/$file" -o json -q > "$2"
}

# security_testssl <host> <out-dir>
#   Runs against 127.0.0.1:443 with the host name as SNI, so the check sees
#   this server's nginx even when DNS points elsewhere (or nowhere yet).
#   Protocols (-p), cipher categories (-s), certificate and server defaults
#   (-S), HTTP headers (-h) and known TLS vulnerabilities (-U); the per-cipher
#   enumeration of a full run takes several minutes and adds nothing we act on.
security_testssl() {
  docker run --rm --network host \
    --user "$(id -u):$(id -g)" \
    -v "$2:/out" \
    "$SECURITY_TESTSSL_IMAGE" \
    --quiet --color 0 --warnings off --sneaky -p -s -S -h -U --ip 127.0.0.1 \
    --jsonfile "/out/testssl-$1.json" "https://$1" > "$2/testssl-$1.log" 2>&1
}
