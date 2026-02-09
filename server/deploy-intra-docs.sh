#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <bundle-zip>"
  exit 1
fi

BUNDLE_ZIP="$1"
BASE_DIR="/srv/intra-docs"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"
TMP_LINK="${BASE_DIR}/.current.$$"
COMPOSE_FILE="/opt/intra-docs/docker-compose.yml"
STAMP="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="${RELEASES_DIR}/${STAMP}"

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "${COMPOSE_FILE}" "$@"
  else
    echo "docker compose not found"
    exit 1
  fi
}

if [[ ! -f "${BUNDLE_ZIP}" ]]; then
  echo "bundle file not found: ${BUNDLE_ZIP}"
  exit 1
fi

mkdir -p "${RELEASES_DIR}" "${RELEASE_DIR}"

set +e
unzip -q "${BUNDLE_ZIP}" -d "${RELEASE_DIR}"
UNZIP_RC=$?
set -e
# unzip return code: 0=ok, 1=warnings (acceptable), >1=error
if [[ ${UNZIP_RC} -gt 1 ]]; then
  echo "unzip failed with code ${UNZIP_RC}"
  rm -rf "${RELEASE_DIR}"
  exit ${UNZIP_RC}
fi

for p in RCOS_API_DOC.html RCOS_API_DOC.assets 5gos_liuyd.html 5gos_liuyd.assets; do
  if [[ ! -e "${RELEASE_DIR}/${p}" ]]; then
    echo "missing required path in bundle: ${p}"
    rm -rf "${RELEASE_DIR}"
    exit 1
  fi
done

rm -f "${TMP_LINK}"
ln -s "${RELEASE_DIR}" "${TMP_LINK}"
if [[ -d "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
  rm -rf "${CURRENT_LINK}"
fi
mv -Tf "${TMP_LINK}" "${CURRENT_LINK}"

if docker ps --format '{{.Names}}' | grep -qx 'intra-docs-nginx'; then
  docker exec intra-docs-nginx nginx -s reload
else
  compose up -d
fi

echo "Deploy success: ${RELEASE_DIR}"
