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
# Convert true/false to 1/0 (SABnzbd expects integer)
if [ "${USENET_SSL_RAW}" = "true" ] || [ "${USENET_SSL_RAW}" = "1" ]; then
  USENET_SSL_VAL="1"
else
  USENET_SSL_VAL="0"
fi
USENET_CONNECTIONS_VAL="${USENET_CONNECTIONS:-10}"

mkdir -p /config

sed \
  -e "s|__SABNZBD_API_KEY__|${SABNZBD_API_KEY}|g" \
  -e "s|__USENET_HOST__|${USENET_HOST}|g" \
  -e "s|__USENET_PORT__|${USENET_PORT}|g" \
  -e "s|__USENET_USER__|${USENET_USER}|g" \
  -e "s|__USENET_PASSWORD__|${USENET_PASSWORD}|g" \
  -e "s|__USENET_CONNECTIONS__|${USENET_CONNECTIONS_VAL}|g" \
  -e "s|__USENET_SSL__|${USENET_SSL_VAL}|g" \
  /opt/openmedia/templates/sabnzbd.ini.template > /config/sabnzbd.ini

echo "[openmedia] sabnzbd.ini written"

# Create required directories with correct ownership (abc user = UID 911)
mkdir -p /downloads/complete /downloads/watched /incomplete-downloads /downloads/nzb_backup /config/scripts /config/logs /config/admin
chown -R abc:abc /downloads /incomplete-downloads

# Write env file for post-process.sh (SABnzbd may not pass parent env to scripts)
# File is deleted after post-process.sh reads it
cat > /opt/openmedia/.env << EOF
OPENMEDIA_JOB_ID=${JOB_ID}
OPENMEDIA_JOB_HASH=${JOB_HASH}
OPENMEDIA_API_BASE_URL=${API_BASE_URL}
OPENMEDIA_SERVICE_TOKEN=${SERVICE_TOKEN}
OPENMEDIA_S3_ENDPOINT=${S3_ENDPOINT}
OPENMEDIA_S3_BUCKET=${S3_BUCKET}
OPENMEDIA_S3_REGION=${S3_REGION}
AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY}
EOF
chmod 600 /opt/openmedia/.env

echo "[openmedia] Configuration complete, SABnzbd will start next"
