#!/usr/bin/with-contenv bash
# ─────────────────────────────────────────────────────────────────
# s6 cont-init.d script: Generates sabnzbd.ini from ENV vars
# Runs BEFORE SABnzbd starts (s6 Stage 2)
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# Source bootstrap config if available (written by 00-fetch-config)
if [ -f /opt/openmedia/api-env.sh ]; then
  echo "[openmedia] Sourcing bootstrap config from /opt/openmedia/api-env.sh"
  # shellcheck disable=SC1091
  source /opt/openmedia/api-env.sh
fi

echo "[openmedia] ============================================="
echo "[openmedia] Generating SABnzbd configuration..."
echo "[openmedia] Job ID:   ${JOB_ID:-not set}"
echo "[openmedia] Job Hash: ${JOB_HASH:0:16}..."
echo "[openmedia] ============================================="

# Validate required environment variables
REQUIRED_VARS=(
  JOB_ID JOB_HASH NZB_URL API_BASE_URL SERVICE_TOKEN
  S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET S3_REGION
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[openmedia] ERROR: $var is not set!"
    exit 1
  fi
done

# At least one Usenet source required
if [ -z "${USENET_SERVERS:-}" ] && [ -z "${USENET_HOST:-}" ]; then
  echo "[openmedia] ERROR: Either USENET_SERVERS (JSON) or USENET_HOST must be set!"
  exit 1
fi

# Generate SABnzbd API key
SABNZBD_API_KEY=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' | head -c 32)
echo "[openmedia] Generated SABnzbd API key"
echo "${SABNZBD_API_KEY}" > /opt/openmedia/sabnzbd-api-key
chmod 600 /opt/openmedia/sabnzbd-api-key

mkdir -p /config

# Build host_whitelist
if [ -n "${DL_HOSTNAME:-}" ]; then
  HOST_WHITELIST="${DL_HOSTNAME}.dl.mediatoken.de"
else
  HOST_WHITELIST=""
fi

# ── Build [servers] section ─────────────────────────────────────
# Writes a SABnzbd-compatible server block for one server.
# Args: host port user pass connections ssl ssl_verify optional priority
write_server_block() {
  local host="$1" port="$2" user="$3" pass="$4" conns="$5" ssl="$6" verify="$7" optional="$8" priority="$9"
  cat >> /tmp/servers-section.ini << SBLKEOF
[[${host}]]
name = ${host}
displayname = ${host}
host = ${host}
port = ${port}
timeout = 60
username = ${user}
password = ${pass}
connections = ${conns}
ssl = ${ssl}
ssl_verify = ${verify}
ssl_ciphers = ""
enable = 1
required = 0
optional = ${optional}
retention = 0
expire_date = ""
quota = ""
usage_at_start = 0
priority = ${priority}
notes = ""
SBLKEOF
}

echo "[servers]" > /tmp/servers-section.ini

if [ -n "${USENET_SERVERS:-}" ]; then
  # ── JSON mode: parse USENET_SERVERS array ───────────────────
  SERVER_COUNT=$(echo "${USENET_SERVERS}" | jq 'length')
  echo "[openmedia] USENET_SERVERS: ${SERVER_COUNT} server(s) from JSON"

  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    S_HOST=$(echo "${USENET_SERVERS}" | jq -r ".[$i].host")
    S_PORT=$(echo "${USENET_SERVERS}" | jq -r ".[$i].port // 563")
    S_USER=$(echo "${USENET_SERVERS}" | jq -r ".[$i].username")
    S_PASS=$(echo "${USENET_SERVERS}" | jq -r ".[$i].password")
    S_CONNS=$(echo "${USENET_SERVERS}" | jq -r ".[$i].connections // 10")
    S_SSL_RAW=$(echo "${USENET_SERVERS}" | jq -r ".[$i].ssl // true")
    S_OPTIONAL=$(echo "${USENET_SERVERS}" | jq -r ".[$i].optional // 0")
    S_PRIORITY=$(echo "${USENET_SERVERS}" | jq -r ".[$i].priority // $i")

    # Convert ssl boolean/string to 1/0
    if [ "${S_SSL_RAW}" = "true" ] || [ "${S_SSL_RAW}" = "1" ]; then
      S_SSL=1
    else
      S_SSL=0
    fi

    write_server_block "${S_HOST}" "${S_PORT}" "${S_USER}" "${S_PASS}" \
      "${S_CONNS}" "${S_SSL}" "2" "${S_OPTIONAL}" "${S_PRIORITY}"

    echo "[openmedia] Server ${i}: ${S_HOST} (priority=${S_PRIORITY}, optional=${S_OPTIONAL})"
  done

else
  # ── Legacy ENV mode: USENET_HOST + optional USENET_BACKUP_HOST ─
  USENET_SSL_RAW="${USENET_SSL:-1}"
  if [ "${USENET_SSL_RAW}" = "true" ] || [ "${USENET_SSL_RAW}" = "1" ]; then
    USENET_SSL_VAL="1"
  else
    USENET_SSL_VAL="0"
  fi

  write_server_block "${USENET_HOST}" "${USENET_PORT:-563}" \
    "${USENET_USER}" "${USENET_PASSWORD}" \
    "${USENET_CONNECTIONS:-10}" "${USENET_SSL_VAL}" "2" "0" "0"
  echo "[openmedia] Primary server: ${USENET_HOST}"

  if [ -n "${USENET_BACKUP_HOST:-}" ] && [ -n "${USENET_BACKUP_USER:-}" ]; then
    BACKUP_SSL_RAW="${USENET_BACKUP_SSL:-1}"
    if [ "${BACKUP_SSL_RAW}" = "true" ] || [ "${BACKUP_SSL_RAW}" = "1" ]; then
      BACKUP_SSL_VAL="1"
    else
      BACKUP_SSL_VAL="0"
    fi

    write_server_block "${USENET_BACKUP_HOST}" "${USENET_BACKUP_PORT:-563}" \
      "${USENET_BACKUP_USER}" "${USENET_BACKUP_PASSWORD}" \
      "${USENET_BACKUP_CONNECTIONS:-10}" "${BACKUP_SSL_VAL}" "2" "1" "1"
    echo "[openmedia] Backup server: ${USENET_BACKUP_HOST}"
  fi
fi

# ── Substitute placeholders in template ─────────────────────────
sed \
  -e "s|__SABNZBD_API_KEY__|${SABNZBD_API_KEY}|g" \
  -e "s|__HOST_WHITELIST__|${HOST_WHITELIST}|g" \
  /opt/openmedia/templates/sabnzbd.ini.template > /tmp/sabnzbd.ini.tmp

# ── Replace __SERVERS_SECTION__ with generated servers ──────────
sed -e '/__SERVERS_SECTION__/{
  r /tmp/servers-section.ini
  d
}' /tmp/sabnzbd.ini.tmp > /config/sabnzbd.ini

rm -f /tmp/sabnzbd.ini.tmp /tmp/servers-section.ini

echo "[openmedia] sabnzbd.ini written"

# ── Verify ──────────────────────────────────────────────────────
BLOCK_COUNT=$(grep -c '^\[\[' /config/sabnzbd.ini || true)
echo "[openmedia] Server blocks in INI: ${BLOCK_COUNT}"

# Create required directories with correct ownership (abc user = UID 911)
mkdir -p /downloads/complete /downloads/watched /incomplete-downloads /downloads/nzb_backup /config/scripts /config/logs /config/admin
chown -R abc:abc /downloads /incomplete-downloads

# Write env file for post-process.sh
cat > /opt/openmedia/.env << EOF
OPENMEDIA_JOB_ID=${JOB_ID}
OPENMEDIA_JOB_HASH=${JOB_HASH}
OPENMEDIA_API_BASE_URL=${API_BASE_URL}
OPENMEDIA_SERVICE_TOKEN=${SERVICE_TOKEN}
OPENMEDIA_S3_ENDPOINT=${S3_ENDPOINT}
OPENMEDIA_S3_BUCKET=${S3_BUCKET}
OPENMEDIA_S3_REGION=${S3_REGION}
OPENMEDIA_S3_ACCESS_KEY=${S3_ACCESS_KEY}
OPENMEDIA_S3_SECRET_KEY=${S3_SECRET_KEY}
EOF
chown abc:abc /opt/openmedia/.env
chmod 600 /opt/openmedia/.env

echo "[openmedia] Configuration complete, SABnzbd will start next"
