#!/usr/bin/with-contenv bash
# ─────────────────────────────────────────────────────────────────
# Downloads NZB, submits to SABnzbd, monitors progress.
# Runs AFTER SABnzbd is ready (called via docker exec or as CMD).
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# Source bootstrap config if available (written by 00-fetch-config)
if [ -f /opt/openmedia/api-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/openmedia/api-env.sh
fi

# disable_api_key=1 in sabnzbd.ini means no key needed.
# Using the generated key would fail after SABnzbd rotates it internally.
SABNZBD_API_KEY=""
if [ -f /opt/openmedia/sabnzbd-api-key ]; then
  SABNZBD_API_KEY=$(cat /opt/openmedia/sabnzbd-api-key)
fi

echo "[openmedia] ============================================="
echo "[openmedia] Submit & Monitor starting"
echo "[openmedia] Job: ${JOB_ID}"
echo "[openmedia] Hash: ${JOB_HASH:0:16}..."
echo "[openmedia] ============================================="

# Warn if API_BASE_URL is not HTTPS (acceptable for local dev, dangerous in production)
if [[ "${API_BASE_URL}" != https://* ]] && [[ "${API_BASE_URL}" != *"localhost"* ]] && [[ "${API_BASE_URL}" != *"host.docker.internal"* ]]; then
  echo "[openmedia] ⚠️  WARNING: API_BASE_URL is not HTTPS — secrets may be transmitted in plaintext!"
fi

# ── Signal "downloading" to API ─────────────────────────────────
echo "[openmedia] Signaling status: downloading"
curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"status":"downloading","progress":5}' || echo "[openmedia] WARNING: Status callback failed"

# ── Wait for SABnzbd to be ready ────────────────────────────────
echo "[openmedia] Waiting for SABnzbd API..."
MAX_WAIT=120
WAITED=0
until curl -sf "http://127.0.0.1:8080/api?apikey=${SABNZBD_API_KEY}&mode=version&output=json" > /dev/null 2>&1; do
  sleep 2
  WAITED=$((WAITED + 2))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[openmedia] ERROR: SABnzbd did not start within ${MAX_WAIT}s"
    curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
      -H "Authorization: Bearer ${SERVICE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"status":"failed","error":"SABnzbd failed to start"}' || true
    exit 1
  fi
done
echo "[openmedia] SABnzbd is ready (waited ${WAITED}s)"

# ── Add backup Usenet server via API (INI parsing is unreliable) ──
if [ -n "${USENET_BACKUP_HOST:-}" ] && [ -n "${USENET_BACKUP_USER:-}" ]; then
  BACKUP_SSL_VAL="1"
  if [ "${USENET_BACKUP_SSL:-1}" = "false" ] || [ "${USENET_BACKUP_SSL:-1}" = "0" ]; then
    BACKUP_SSL_VAL="0"
  fi
  echo "[openmedia] Adding backup server: ${USENET_BACKUP_HOST}"
  curl -sf "http://127.0.0.1:8080/api?apikey=${SABNZBD_API_KEY}&mode=config&name=set_server&keyword=set_server&output=json" \
    --data-urlencode "host=${USENET_BACKUP_HOST}" \
    --data-urlencode "port=${USENET_BACKUP_PORT:-563}" \
    --data-urlencode "username=${USENET_BACKUP_USER}" \
    --data-urlencode "password=${USENET_BACKUP_PASSWORD}" \
    --data-urlencode "connections=${USENET_BACKUP_CONNECTIONS:-10}" \
    --data-urlencode "ssl=${BACKUP_SSL_VAL}" \
    --data-urlencode "ssl_verify=2" \
    --data-urlencode "enable=1" \
    --data-urlencode "optional=1" \
    --data-urlencode "priority=1" \
    --data-urlencode "displayname=${USENET_BACKUP_HOST}" \
    > /dev/null 2>&1 && echo "[openmedia] Backup server added" \
    || echo "[openmedia] WARNING: Failed to add backup server"
fi

# ── Download NZB file from NZB service ─────────────────────────
echo "[openmedia] Downloading NZB file..."
mkdir -p /downloads/staging
NZB_FILE="/downloads/staging/${JOB_HASH}.nzb"

HTTP_STATUS=$(curl -sf -w "%{http_code}" \
  -o "${NZB_FILE}" \
  "${NZB_URL}")

if [ "$HTTP_STATUS" != "200" ] || [ ! -s "${NZB_FILE}" ]; then
  echo "[openmedia] ERROR: Failed to download NZB (HTTP ${HTTP_STATUS})"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"failed\",\"error\":\"NZB download failed (HTTP ${HTTP_STATUS})\"}" || true
  exit 1
fi
echo "[openmedia] NZB file downloaded"

# ── Submit NZB to SABnzbd with hash as job name ─────────────────
echo "[openmedia] Submitting NZB to SABnzbd (name: ${JOB_HASH:0:16}...)..."

SUBMIT_RESPONSE=$(curl -sf \
  "http://127.0.0.1:8080/api?apikey=${SABNZBD_API_KEY}&mode=addlocalfile&name=${NZB_FILE}&nzbname=${JOB_HASH}&pp=3&output=json")

echo "[openmedia] SABnzbd response: ${SUBMIT_RESPONSE}"

NZO_ID=$(echo "${SUBMIT_RESPONSE}" | grep -o '"SABnzbd_nzo_[^"]*"' | tr -d '"' | head -1)
if [ -z "${NZO_ID}" ]; then
  echo "[openmedia] ERROR: NZB submission failed"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"status":"failed","error":"SABnzbd rejected NZB"}' || true
  exit 1
fi
echo "[openmedia] NZB queued: ${NZO_ID}"

curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"status":"downloading","progress":10}' || true

# ── Monitor SABnzbd until job completes ─────────────────────────
echo "[openmedia] Monitoring download progress..."

POLL_INTERVAL=15
MAX_RUNTIME=21600  # 6 hours max
ELAPSED=0
LAST_PROGRESS=10

while [ $ELAPSED -lt $MAX_RUNTIME ]; do
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  HISTORY_JSON=$(curl -sf "http://127.0.0.1:8080/api?apikey=${SABNZBD_API_KEY}&mode=history&output=json" 2>/dev/null || echo "")

  # Check if post-process already signaled completion (faster than polling SABnzbd)
  if [ -f /tmp/openmedia-upload-done ]; then
    echo "[openmedia] Post-process signaled completion (upload done file found)"
    break
  fi

  if echo "${HISTORY_JSON}" | grep -q "${JOB_HASH}"; then
    JOB_STATUS=$(echo "${HISTORY_JSON}" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "${JOB_STATUS}" = "Completed" ]; then
      echo "[openmedia] SABnzbd reports: Completed! Waiting for post-process..."
      # Wait for post-process to finish S3 upload + API callback
      PP_WAIT=0
      while [ $PP_WAIT -lt 600 ]; do
        if [ -f /tmp/openmedia-upload-done ]; then
          echo "[openmedia] Post-process finished (waited ${PP_WAIT}s)"
          break
        fi
        sleep 5
        PP_WAIT=$((PP_WAIT + 5))
      done
      break
    elif [ "${JOB_STATUS}" = "Failed" ]; then
      FAIL_MSG=$(echo "${HISTORY_JSON}" | grep -o '"fail_message":"[^"]*"' | head -1 | cut -d'"' -f4)
      echo "[openmedia] SABnzbd reports: Failed! Reason: ${FAIL_MSG}"
      curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
        -H "Authorization: Bearer ${SERVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"failed\",\"error\":\"SABnzbd: ${FAIL_MSG}\"}" || true
      break
    fi
  fi

  # Update progress from queue
  QUEUE_JSON=$(curl -sf "http://127.0.0.1:8080/api?apikey=${SABNZBD_API_KEY}&mode=queue&output=json" 2>/dev/null || echo "")
  if echo "${QUEUE_JSON}" | grep -q "${JOB_HASH}"; then
    PERCENTAGE=$(echo "${QUEUE_JSON}" | grep -o '"percentage":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "${PERCENTAGE}" ]; then
      MAPPED_PROGRESS=$(( 10 + (PERCENTAGE * 65 / 100) ))
      if [ $MAPPED_PROGRESS -ne $LAST_PROGRESS ]; then
        LAST_PROGRESS=$MAPPED_PROGRESS
        echo "[openmedia] Progress: ${PERCENTAGE}% (mapped: ${MAPPED_PROGRESS}%)"
        curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
          -H "Authorization: Bearer ${SERVICE_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"status\":\"downloading\",\"progress\":${MAPPED_PROGRESS}}" || true
      fi
    fi
  fi
done

if [ $ELAPSED -ge $MAX_RUNTIME ]; then
  echo "[openmedia] ERROR: Timeout after ${MAX_RUNTIME}s"
  curl -sf -X PATCH "${API_BASE_URL}/downloads/jobs/${JOB_ID}/status" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"status":"failed","error":"Download timeout (6h)"}' || true
fi

# Check final status
sleep 10
FINAL_STATUS=$(curl -sf \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
  "${API_BASE_URL}/downloads/jobs/${JOB_ID}" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

echo "[openmedia] Final status: ${FINAL_STATUS}"

# ── Shutdown container ──────────────────────────────────────────
# Stop s6 supervision tree → all services stop → container exits →
# cloud-init's docker wait returns → self-cleanup fires.
echo "[openmedia] Shutting down container..."
if command -v s6-svscanctl > /dev/null 2>&1; then
  # s6-overlay v3: signal s6-svscan to bring everything down
  s6-svscanctl -t /run/service 2>/dev/null || true
else
  # Fallback: kill PID 1 (init process)
  kill 1 2>/dev/null || true
fi

echo "[openmedia] Container finished."
