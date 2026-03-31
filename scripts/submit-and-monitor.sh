#!/usr/bin/with-contenv bash
# ─────────────────────────────────────────────────────────────────
# Downloads NZB, submits to SABnzbd, monitors progress.
# Runs AFTER SABnzbd is ready (called via docker exec or as CMD).
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SABNZBD_API_KEY=$(cat /opt/openmedia/sabnzbd-api-key)

echo "[openmedia] ============================================="
echo "[openmedia] Submit & Monitor starting"
echo "[openmedia] Job: ${JOB_ID}"
echo "[openmedia] Hash: ${JOB_HASH:0:16}..."
echo "[openmedia] ============================================="

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

# ── Download NZB file from API ──────────────────────────────────
echo "[openmedia] Downloading NZB file..."
NZB_FILE="/downloads/watched/${JOB_HASH}.nzb"

HTTP_STATUS=$(curl -sf -w "%{http_code}" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" \
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

  if echo "${HISTORY_JSON}" | grep -q "${JOB_HASH}"; then
    JOB_STATUS=$(echo "${HISTORY_JSON}" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "${JOB_STATUS}" = "Completed" ]; then
      echo "[openmedia] SABnzbd reports: Completed! Post-processing will handle the rest."
      # post-process.sh handles S3 upload + API callback
      # Wait for it to finish
      sleep 30
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
          -d "{\"progress\":${MAPPED_PROGRESS}}" || true
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
echo "[openmedia] Container finished."
