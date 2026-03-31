#!/bin/bash
set -euo pipefail

echo "============================================="
echo "[openmedia-downloader] Starting..."
echo "[openmedia-downloader] Job ID:   ${JOB_ID:-not set}"
echo "[openmedia-downloader] Job Hash: ${JOB_HASH:0:16}..."
echo "============================================="

# ── Validate required environment variables ──────────────────────
REQUIRED_VARS=(
  JOB_ID JOB_HASH NZB_URL API_BASE_URL SERVICE_TOKEN
  USENET_HOST USENET_PORT USENET_USER USENET_PASSWORD
  S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET S3_REGION
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[openmedia-downloader] ERROR: $var is not set!"
    # Signal failure to API if we can
    if [ -n "${API_BASE_URL:-}" ] && [ -n "${SERVICE_TOKEN:-}" ] && [ -n "${JOB_ID:-}" ]; then
      curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
        -H "Authorization: Bearer ${SERVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"failed\",\"error\":\"Missing required env var: ${var}\"}" || true
    fi
    exit 1
  fi
done

# ── Generate SABnzbd API key ────────────────────────────────────
SABNZBD_API_KEY=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' | head -c 32)
echo "[openmedia-downloader] Generated SABnzbd API key"

# ── Generate sabnzbd.ini from template ──────────────────────────
echo "[openmedia-downloader] Generating sabnzbd.ini..."

USENET_SSL_VAL="${USENET_SSL:-1}"
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

echo "[openmedia-downloader] sabnzbd.ini written"

# ── Create directories ──────────────────────────────────────────
mkdir -p /downloads/complete /downloads/watched /incomplete-downloads /downloads/nzb_backup /config/scripts /config/logs /config/admin

# ── Export S3 credentials for post-process.sh ───────────────────
# These are available as env vars to SABnzbd's child processes
export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}"
# Also export our custom vars so post-process.sh can read them
export OPENMEDIA_JOB_ID="${JOB_ID}"
export OPENMEDIA_JOB_HASH="${JOB_HASH}"
export OPENMEDIA_API_BASE_URL="${API_BASE_URL}"
export OPENMEDIA_SERVICE_TOKEN="${SERVICE_TOKEN}"
export OPENMEDIA_S3_ENDPOINT="${S3_ENDPOINT}"
export OPENMEDIA_S3_BUCKET="${S3_BUCKET}"
export OPENMEDIA_S3_REGION="${S3_REGION}"

# Write env vars to a file so post-process.sh can source them
# (SABnzbd may not pass all parent env vars to scripts)
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

# ── Signal "downloading" to API ─────────────────────────────────
echo "[openmedia-downloader] Signaling status: downloading"
curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"status":"downloading","progress":5}' || echo "[openmedia-downloader] WARNING: Status callback failed"

# ── Start SABnzbd via linuxserver init system ───────────────────
echo "[openmedia-downloader] Starting SABnzbd..."

# Start the linuxserver init in background
/init &
SAB_PID=$!

# ── Wait for SABnzbd to be ready ────────────────────────────────
echo "[openmedia-downloader] Waiting for SABnzbd API..."
MAX_WAIT=120
WAITED=0
until curl -sf "http://127.0.0.1:8080/sabnzbd/api?apikey=${SABNZBD_API_KEY}&mode=version&output=json" > /dev/null 2>&1; do
  sleep 2
  WAITED=$((WAITED + 2))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[openmedia-downloader] ERROR: SABnzbd did not start within ${MAX_WAIT}s"
    curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
      -H "Authorization: Bearer ${SERVICE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"status":"failed","error":"SABnzbd failed to start"}' || true
    exit 1
  fi
done
echo "[openmedia-downloader] SABnzbd is ready (waited ${WAITED}s)"

# ── Download NZB file from API ──────────────────────────────────
echo "[openmedia-downloader] Downloading NZB file..."
NZB_FILE="/downloads/watched/${JOB_HASH}.nzb"

HTTP_STATUS=$(curl -sf -w "%{http_code}" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  -o "${NZB_FILE}" \
  "${NZB_URL}")

if [ "$HTTP_STATUS" != "200" ] || [ ! -s "${NZB_FILE}" ]; then
  echo "[openmedia-downloader] ERROR: Failed to download NZB (HTTP ${HTTP_STATUS})"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"failed\",\"error\":\"NZB download failed (HTTP ${HTTP_STATUS})\"}" || true
  exit 1
fi
echo "[openmedia-downloader] NZB file downloaded ($(stat -c%s "${NZB_FILE}" 2>/dev/null || stat -f%z "${NZB_FILE}") bytes)"

# ── Submit NZB to SABnzbd with hash as job name ─────────────────
echo "[openmedia-downloader] Submitting NZB to SABnzbd (name: ${JOB_HASH:0:16}...)..."

SUBMIT_RESPONSE=$(curl -sf \
  "http://127.0.0.1:8080/sabnzbd/api?apikey=${SABNZBD_API_KEY}&mode=addlocalfile&name=${NZB_FILE}&nzbname=${JOB_HASH}&pp=3&output=json")

echo "[openmedia-downloader] SABnzbd response: ${SUBMIT_RESPONSE}"

# Verify submission
NZO_ID=$(echo "${SUBMIT_RESPONSE}" | grep -o '"SABnzbd_nzo_[^"]*"' | tr -d '"' | head -1)
if [ -z "${NZO_ID}" ]; then
  echo "[openmedia-downloader] ERROR: NZB submission failed"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"failed\",\"error\":\"SABnzbd rejected NZB\"}" || true
  exit 1
fi
echo "[openmedia-downloader] NZB queued: ${NZO_ID}"

# ── Update progress: downloading ────────────────────────────────
curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"status":"downloading","progress":10}' || true

# ── Monitor SABnzbd until job completes ─────────────────────────
echo "[openmedia-downloader] Monitoring download progress..."

POLL_INTERVAL=15
MAX_RUNTIME=21600  # 6 hours max
ELAPSED=0
LAST_PROGRESS=10

while [ $ELAPSED -lt $MAX_RUNTIME ]; do
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Check queue status
  QUEUE_JSON=$(curl -sf "http://127.0.0.1:8080/sabnzbd/api?apikey=${SABNZBD_API_KEY}&mode=queue&output=json" 2>/dev/null || echo "")
  HISTORY_JSON=$(curl -sf "http://127.0.0.1:8080/sabnzbd/api?apikey=${SABNZBD_API_KEY}&mode=history&output=json" 2>/dev/null || echo "")

  # Check if job is in history (completed or failed)
  if echo "${HISTORY_JSON}" | grep -q "${JOB_HASH}"; then
    JOB_STATUS=$(echo "${HISTORY_JSON}" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "${JOB_STATUS}" = "Completed" ]; then
      echo "[openmedia-downloader] SABnzbd reports: Completed!"
      echo "[openmedia-downloader] Post-processing script will handle S3 upload and API callback."
      # Post-process.sh handles the rest (S3 upload + API callback)
      # Wait a bit for post-processing to finish
      sleep 30
      break
    elif [ "${JOB_STATUS}" = "Failed" ]; then
      FAIL_MSG=$(echo "${HISTORY_JSON}" | grep -o '"fail_message":"[^"]*"' | head -1 | cut -d'"' -f4)
      echo "[openmedia-downloader] SABnzbd reports: Failed! Reason: ${FAIL_MSG}"
      curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
        -H "Authorization: Bearer ${SERVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"failed\",\"error\":\"SABnzbd: ${FAIL_MSG}\"}" || true
      break
    fi
  fi

  # Update progress from queue percentage
  if echo "${QUEUE_JSON}" | grep -q "${JOB_HASH}"; then
    PERCENTAGE=$(echo "${QUEUE_JSON}" | grep -o '"percentage":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "${PERCENTAGE}" ]; then
      # Map SABnzbd 0-100 to our 10-75 range (75-100 is for upload)
      MAPPED_PROGRESS=$(( 10 + (PERCENTAGE * 65 / 100) ))
      if [ $MAPPED_PROGRESS -ne $LAST_PROGRESS ]; then
        LAST_PROGRESS=$MAPPED_PROGRESS
        echo "[openmedia-downloader] Progress: ${PERCENTAGE}% (mapped: ${MAPPED_PROGRESS}%)"
        curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
          -H "Authorization: Bearer ${SERVICE_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"progress\":${MAPPED_PROGRESS}}" || true
      fi
    fi
  fi
done

if [ $ELAPSED -ge $MAX_RUNTIME ]; then
  echo "[openmedia-downloader] ERROR: Timeout after ${MAX_RUNTIME}s"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"status":"failed","error":"Download timeout (6h)"}' || true
fi

# ── Wait for post-process.sh to complete, then check final status
echo "[openmedia-downloader] Checking final job status..."
sleep 10

# Check if the API job is now completed (post-process.sh would have updated it)
FINAL_STATUS=$(curl -sf \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  "${API_BASE_URL}/downloads/jobs/${JOB_ID}" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

echo "[openmedia-downloader] Final status: ${FINAL_STATUS}"

if [ "${FINAL_STATUS}" = "completed" ]; then
  echo "[openmedia-downloader] ✅ Job completed successfully!"
else
  echo "[openmedia-downloader] ⚠️ Job ended with status: ${FINAL_STATUS}"
fi

echo "[openmedia-downloader] Container finished. VPS can be destroyed."
# Keep container alive briefly so logs can be collected
sleep 30
exit 0
