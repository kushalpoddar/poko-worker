#!/usr/bin/env bash
# Self-hosted Poko worker — run on a Linux VPS (Ubuntu/Debian).
#   curl -fsSL https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh | bash
# Or export POKO_TOKEN, POKO_WORKSPACE_ID, POKO_API_KEY first for non-interactive install.

set -euo pipefail

INSTALLER_URL="${POKO_INSTALLER_URL:-https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh}"
# curl | bash leaves the script on stdin — re-exec from a file so prompts work.
if [[ ! -t 0 ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL "$INSTALLER_URL" -o "$tmp"
  chmod +x "$tmp"
  exec bash "$tmp" "$@"
fi

POKO_WORKER_VERSION="${POKO_WORKER_VERSION:-0.4.0}"
POKO_IMAGE="ghcr.io/kushalpoddar/ai-ads/poko-worker:${POKO_WORKER_VERSION}"
POKO_API_BASE="${POKO_API_BASE:-https://api.poko.video}"
INSTALL_DIR="${POKO_INSTALL_DIR:-${HOME}/poko-worker}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKIP_PUBLIC_URL="${POKO_SKIP_PUBLIC_URL:-}"
SKIP_DNS_CHECK="${POKO_SKIP_DNS_CHECK:-}"

info() { printf '→ %s\n' "$*"; }
ok() { printf '✅ %s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Poko worker installer (Linux VPS)

Environment (optional — prompts if missing):
  POKO_PUBLIC_URL       https://video.example.com  (or hostname; required unless skip)
  POKO_TOKEN            desktop session (lm_…)
  POKO_WORKSPACE_ID     workspace id
  POKO_API_KEY          caller key (poko_live_…)
  POKO_API_BASE         default: https://api.poko.video
  POKO_WORKER_VERSION   default: ${POKO_WORKER_VERSION}
  POKO_INSTALL_DIR      default: ~/poko-worker
  POKO_SKIP_PUBLIC_URL  set to 1 to skip TLS (loopback only)
  POKO_SKIP_DNS_CHECK   set to 1 if DNS is not visible from this box yet

Example:
  export POKO_TOKEN=lm_… POKO_WORKSPACE_ID=… POKO_API_KEY=poko_live_…
  bash install.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0

[[ "$(uname -s)" == "Linux" ]] || die "Run this on a Linux VPS (not macOS)."

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Need root or sudo to install Docker."
  SUDO="sudo"
fi

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif ${SUDO} docker info >/dev/null 2>&1; then
    ${SUDO} docker "$@"
  else
    return 1
  fi
}

ensure_docker() {
  if docker_cmd version >/dev/null 2>&1; then
    ok "Docker: $(docker_cmd version --format '{{.Server.Version}}' 2>/dev/null || docker_cmd --version)"
    return
  fi

  info "Installing Docker…"
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y ca-certificates curl
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  ${SUDO} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(${SUDO} dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(${SUDO} bash -c '. /etc/os-release && echo "$VERSION_CODENAME"') stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  if [[ -n "${SUDO}" ]] && id -nG "${USER}" 2>/dev/null | grep -vq docker; then
    ${SUDO} usermod -aG docker "${USER}" || true
    ok "Docker installed. If the next step fails with permission denied, run: newgrp docker"
  fi

  docker_cmd version >/dev/null 2>&1 || die "Docker install failed."
  ok "Docker installed"
}

prompt_if_empty() {
  local var_name="$1" prompt="$2" secret="${3:-0}"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    return
  fi
  # curl | bash pipes the script on stdin — read prompts from the terminal.
  if [[ "${secret}" == "1" ]]; then
    read -rsp "${prompt}: " current </dev/tty
    echo >&2
  else
    read -rp "${prompt}: " current </dev/tty
  fi
  [[ -n "${current}" ]] || die "${var_name} is required."
  printf -v "${var_name}" '%s' "${current}"
}

normalize_public_host() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  raw="${raw#http://}"
  raw="${raw#https://}"
  raw="${raw%%/*}"
  raw="${raw%%:*}"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

this_public_ip() {
  curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' \
    || curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' \
    || true
}

resolve_host_ips() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" | grep -E '^[0-9.]+$' || true
  elif command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$host" | awk '{print $1}' | sort -u || true
  else
    python3 - "$host" <<'PY' 2>/dev/null || true
import socket, sys
try:
    print("\n".join(sorted({ai[4][0] for ai in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except OSError:
    pass
PY
  fi
}

ensure_public_url() {
  PUBLIC_HOST=""
  if [[ "${SKIP_PUBLIC_URL}" == "1" ]]; then
    POKO_PUBLIC_URL=""
    return
  fi
  if [[ -z "${POKO_PUBLIC_URL:-}" ]]; then
    echo
    echo "Point DNS here first (A record → this VPS), then enter that hostname."
    echo "  Example: video.example.com   or   https://video.example.com"
    echo "  Type skip to install without a public URL (loopback only)."
    read -rp "Public URL: " POKO_PUBLIC_URL </dev/tty || true
  fi
  local trimmed
  trimmed="$(printf '%s' "${POKO_PUBLIC_URL:-}" | tr -d '[:space:]')"
  if [[ -z "${trimmed}" || "${trimmed}" == "skip" ]]; then
    POKO_PUBLIC_URL=""
    info "Skipping public URL — worker stays on 127.0.0.1:8787"
    return
  fi
  PUBLIC_HOST="$(normalize_public_host "$trimmed")"
  [[ -n "${PUBLIC_HOST}" ]] || die "Could not parse hostname from that URL."
  POKO_PUBLIC_URL="https://${PUBLIC_HOST}"
  info "Using ${POKO_PUBLIC_URL}"

  if [[ "${SKIP_DNS_CHECK}" == "1" ]]; then
    return
  fi
  local box_ip resolved
  box_ip="$(this_public_ip)"
  resolved="$(resolve_host_ips "${PUBLIC_HOST}")"
  if [[ -z "${resolved}" ]]; then
    die "${PUBLIC_HOST} does not resolve yet. Add an A record to this VPS, wait, then run: dig +short ${PUBLIC_HOST}"
  fi
  if [[ -n "${box_ip}" ]] && ! printf '%s\n' "${resolved}" | grep -qx "${box_ip}"; then
    die "${PUBLIC_HOST} points at $(printf '%s' "${resolved}" | tr '\n' ' ')— this box is ${box_ip}. Fix the A record, then re-run."
  fi
  ok "DNS ${PUBLIC_HOST} → ${box_ip:-ok}"
}

ensure_public_url
prompt_if_empty POKO_TOKEN "POKO_TOKEN (lm_… from desktop session)" 1
prompt_if_empty POKO_WORKSPACE_ID "POKO_WORKSPACE_ID"
prompt_if_empty POKO_API_KEY "POKO_API_KEY (poko_live_…)" 1

mkdir -p "${INSTALL_DIR}"
info "Installing to ${INSTALL_DIR}"

cat > "${INSTALL_DIR}/.env" <<EOF
POKO_TOKEN=${POKO_TOKEN}
POKO_WORKSPACE_ID=${POKO_WORKSPACE_ID}
POKO_API_BASE=${POKO_API_BASE}
POKO_API_KEY=${POKO_API_KEY}
POKO_PUBLIC_URL=${POKO_PUBLIC_URL}
EOF
chmod 600 "${INSTALL_DIR}/.env"

write_compose() {
  if [[ -f "${SCRIPT_DIR}/docker-compose.prod.yml" ]]; then
    sed "s|ghcr.io/kushalpoddar/ai-ads/poko-worker:[^[:space:]]*|${POKO_IMAGE}|" \
      "${SCRIPT_DIR}/docker-compose.prod.yml" > "${INSTALL_DIR}/docker-compose.yml"
  else
    cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  poko-worker:
    platform: linux/amd64
    image: ${POKO_IMAGE}
    container_name: poko-worker
    ports:
      - "127.0.0.1:8787:8787"
    env_file:
      - .env
    environment:
      POKO_DATA_DIR: /var/lib/poko
    volumes:
      - poko-data:/var/lib/poko
    shm_size: "1gb"
    restart: unless-stopped
    mem_limit: 4g
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "7"

  caddy:
    profiles: ["tls"]
    image: caddy:2-alpine
    container_name: poko-worker-caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - poko-worker
    restart: unless-stopped

volumes:
  poko-data:
  caddy-data:
  caddy-config:
EOF
  fi
}

write_compose

TLS_ARGS=()
if [[ -n "${PUBLIC_HOST}" ]]; then
  cat > "${INSTALL_DIR}/Caddyfile" <<EOF
${PUBLIC_HOST} {
  reverse_proxy poko-worker:8787
}
EOF
  TLS_ARGS=(--profile tls)
  info "Caddy TLS for ${PUBLIC_HOST}"
fi

ensure_docker

cd "${INSTALL_DIR}"
info "Pulling ${POKO_IMAGE}…"
docker_cmd compose pull
info "Starting worker…"
docker_cmd compose "${TLS_ARGS[@]}" up -d

info "Waiting for worker…"
ready=0
for _ in $(seq 1 30); do
  if curl -sf -H "Authorization: Bearer ${POKO_API_KEY}" "http://127.0.0.1:8787/automations/v1/status" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "${ready}" -eq 1 ]]; then
  ok "Worker is online (ingress: self-hosted)"
else
  die "Worker did not respond. Check logs: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs poko-worker"
fi

echo
ok "Done"
echo "  Local:  curl -H \"Authorization: Bearer \$POKO_API_KEY\" http://127.0.0.1:8787/automations/v1/status"
if [[ -n "${PUBLIC_HOST}" ]]; then
  echo "  Public: https://${PUBLIC_HOST}/automations/v1/status"
else
  echo "  Add a domain + re-run with POKO_PUBLIC_URL, or put nginx/Caddy in front of 127.0.0.1:8787"
fi
echo "  Logs:   cd ${INSTALL_DIR} && docker compose logs -f poko-worker"
