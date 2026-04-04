#!/usr/bin/with-contenv bash
# ─────────────────────────────────────────────────────────────────
# s6 cont-init.d script: Generates sabnzbd.ini from ENV vars
# Runs BEFORE SABnzbd starts (s6 Stage 2)
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

echo "[openmedia] ============================================="
echo "[openmedia] Generating SABnzbd configuration..."
echo "[openmedia] Job ID:   ${JOB_ID:-not set}"
echo "[openmedia] Job Hash: ${JOB_HASH:0:16}..."
echo "[openmedia] ============================================="

# Validate required environment variables
REQUIRED_VARS=(
  JOB_ID JOB_HASH NZB_URL API_BASE_URL SERVICE_TOKEN
  USENET_HOST USENET_PORT USENET_USER USENET_PASSWORD
  S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET S3_REGION
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[openmedia] ERROR: $var is not set!"
    exit 1
  fi
done

# Generate SABnzbd API key
SABNZBD_API_KEY=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' | head -c 32)
echo "[openmedia] Generated SABnzbd API key"

# Save API key for submit-and-monitor.sh
echo "${SABNZBD_API_KEY}" > /opt/openmedia/sabnzbd-api-key
chmod 600 /opt/openmedia/sabnzbd-api-key

# Generate sabnzbd.ini from template
USENET_SSL_RAW="${USENET_SSL:-1}"
if [ "${USENET_SSL_RAW}" = "true" ] || [ "${USENET_SSL_RAW}" = "1" ]; then
  USENET_SSL_VAL="1"
else
  USENET_SSL_VAL="0"
fi
USENET_CONNECTIONS_VAL="${USENET_CONNECTIONS:-10}"

mkdir -p /config

# Build host_whitelist
if [ -n "${DL_HOSTNAME:-}" ]; then
  HOST_WHITELIST="${DL_HOSTNAME}.dl.mediatoken.de"
else
  HOST_WHITELIST=""
fi

# ── Build complete [servers] section as a file ──────────────────
cat > /tmp/servers-section.ini << SRVEOF
[servers]
[[${USENET_HOST}]]
name = ${USENET_HOST}
displayname = ${USENET_HOST}
host = ${USENET_HOST}
port = ${USENET_PORT}
timeout = 60
username = ${USENET_USER}
password = ${USENET_PASSWORD}
connections = ${USENET_CONNECTIONS_VAL}
ssl = ${USENET_SSL_VAL}
ssl_verify = 2
ssl_ciphers = ""
enable = 1
required = 0
optional = 0
retention = 0
expire_date = ""
quota = ""
usage_at_start = 0
priority = 0
notes = ""
SRVEOF

echo "[openmedia] Primary server: ${USENET_HOST}"

# Append backup server if configured
if [ -n "${USENET_BACKUP_HOST:-}" ] && [ -n "${USENET_BACKUP_USER:-}" ]; then
  BACKUP_SSL_RAW="${USENET_BACKUP_SSL:-1}"
  if [ "${BACKUP_SSL_RAW}" = "true" ] || [ "${BACKUP_SSL_RAW}" = "1" ]; then
    BACKUP_SSL_VAL="1"
  else
    BACKUP_SSL_VAL="0"
  fi
  BACKUP_CONNECTIONS="${USENET_BACKUP_CONNECTIONS:-10}"
  BACKUP_PORT="${USENET_BACKUP_PORT:-563}"

  cat >> /tmp/servers-section.ini << BKPEOF
[[${USENET_BACKUP_HOST}]]
name = ${USENET_BACKUP_HOST}
displayname = ${USENET_BACKUP_HOST}
host = ${USENET_BACKUP_HOST}
port = ${BACKUP_PORT}
timeout = 60
username = ${USENET_BACKUP_USER}
password = ${USENET_BACKUP_PASSWORD}
connections = ${BACKUP_CONNECTIONS}
ssl = ${BACKUP_SSL_VAL}
ssl_verify = 2
ssl_ciphers = ""
enable = 1
required = 0
optional = 1
retention = 0
expire_date = ""
quota = ""
usage_at_start = 0
priority = 1
notes = ""
BKPEOF
  echo "[openmedia] Backup server: ${USENET_BACKUP_HOST}"
else
  echo "[openmedia] No backup server configured"
fi

# ── Substitute placeholders in template (except servers) ────────
sed \
  -e "s|__SABNZBD_API_KEY__|${SABNZBD_API_KEY}|g" \
  -e "s|__HOST_WHITELIST__|${HOST_WHITELIST}|g" \
  /opt/openmedia/templates/sabnzbd.ini.template > /tmp/sabnzbd.ini.tmp

# ── Replace __SERVERS_SECTION__ with the generated servers file ─
sed -e '/__SERVERS_SECTION__/{
  r /tmp/servers-section.ini
  d
}' /tmp/sabnzbd.ini.tmp > /config/sabnzbd.ini

rm -f /tmp/sabnzbd.ini.tmp /tmp/servers-section.ini

echo "[openmedia] sabnzbd.ini written"

# ── Verify server count ─────────────────────────────────────────
SERVER_COUNT=$(grep -c '^\[\[' /config/sabnzbd.ini || true)
echo "[openmedia] Server blocks in INI: ${SERVER_COUNT}"

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
