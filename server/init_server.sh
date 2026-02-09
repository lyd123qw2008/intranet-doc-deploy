#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

BASE_DIR="/srv/intra-docs"
RELEASES_DIR="${BASE_DIR}/releases"
DEPLOY_SCRIPT="/usr/local/bin/deploy-intra-docs.sh"
APP_DIR="/opt/intra-docs"
NGINX_DIR="${APP_DIR}/nginx"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_SCRIPT_SOURCE="${SCRIPT_DIR}/deploy-intra-docs.sh"
NGINX_CONF_SOURCE="${PROJECT_ROOT}/nginx/intra-docs.conf"
COMPOSE_SOURCE="${PROJECT_ROOT}/docker-compose.yml"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found. please install docker first."
  exit 1
fi

mkdir -p "${RELEASES_DIR}" "${NGINX_DIR}"

cp -f "${DEPLOY_SCRIPT_SOURCE}" "${DEPLOY_SCRIPT}"
chmod +x "${DEPLOY_SCRIPT}"
cp -f "${NGINX_CONF_SOURCE}" "${NGINX_DIR}/intra-docs.conf"
cp -f "${COMPOSE_SOURCE}" "${COMPOSE_FILE}"

if docker compose version >/dev/null 2>&1; then
  docker compose -f "${COMPOSE_FILE}" up -d
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "${COMPOSE_FILE}" up -d
else
  echo "docker compose plugin not found. please install docker compose plugin or docker-compose."
  exit 1
fi

echo "Server init done (Docker Nginx)."
echo "Compose file: ${COMPOSE_FILE}"
echo "Deploy script: ${DEPLOY_SCRIPT}"
