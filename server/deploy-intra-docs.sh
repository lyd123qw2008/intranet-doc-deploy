#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <bundle-file>"
  exit 1
fi

BUNDLE_FILE="$1"
BASE_DIR="/srv/intra-docs"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"
TMP_LINK="${BASE_DIR}/.current.$$"
COMPOSE_FILE="/opt/intra-docs/docker-compose.yml"
KEEP_RELEASES="${KEEP_RELEASES:-20}"
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

if [[ ! -f "${BUNDLE_FILE}" ]]; then
  echo "bundle file not found: ${BUNDLE_FILE}"
  exit 1
fi

mkdir -p "${RELEASES_DIR}" "${RELEASE_DIR}"

if [[ "${BUNDLE_FILE}" == *.tar.gz || "${BUNDLE_FILE}" == *.tgz ]]; then
  tar -xzf "${BUNDLE_FILE}" -C "${RELEASE_DIR}"
elif [[ "${BUNDLE_FILE}" == *.zip ]]; then
  set +e
  unzip -q "${BUNDLE_FILE}" -d "${RELEASE_DIR}"
  UNZIP_RC=$?
  set -e
  # unzip return code: 0=ok, 1=warnings (acceptable), >1=error
  if [[ ${UNZIP_RC} -gt 1 ]]; then
    echo "unzip failed with code ${UNZIP_RC}"
    rm -rf "${RELEASE_DIR}"
    exit ${UNZIP_RC}
  fi
else
  echo "unsupported bundle format: ${BUNDLE_FILE}"
  rm -rf "${RELEASE_DIR}"
  exit 1
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

# Keep recent releases only (default: 20) to avoid unbounded disk growth.
if [[ "${KEEP_RELEASES}" =~ ^[0-9]+$ ]] && [[ "${KEEP_RELEASES}" -ge 1 ]]; then
  CURRENT_REAL="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"
  mapfile -t ALL_RELEASES < <(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
  RELEASE_COUNT="${#ALL_RELEASES[@]}"
  if [[ "${RELEASE_COUNT}" -gt "${KEEP_RELEASES}" ]]; then
    REMOVE_COUNT=$((RELEASE_COUNT - KEEP_RELEASES))
    for ((i=0; i<REMOVE_COUNT; i++)); do
      OLD="${ALL_RELEASES[$i]}"
      if [[ -n "${CURRENT_REAL}" && "${OLD}" == "${CURRENT_REAL}" ]]; then
        continue
      fi
      rm -rf "${OLD}"
    done
  fi
fi

echo "Deploy success: ${RELEASE_DIR}"
