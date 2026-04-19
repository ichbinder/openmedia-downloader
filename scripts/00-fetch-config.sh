#!/usr/bin/with-contenv bash
# ─────────────────────────────────────────────────────────────────
# s6 cont-init.d script: Fetches config from API at boot
# Runs BEFORE 10-generate-config (s6 ordering by filename)
#
# Requires 3 ENV vars from cloud-init:
#   API_BASE_URL, SERVICE_TOKEN, JOB_ID
#
# Backward compat: if legacy ENV vars (USENET_SERVERS/USENET_HOST)
# are already set, skip API calls entirely.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

API_ENV_FILE="/opt/openmedia/api-env.sh"

# ── Backward compatibility: legacy ENV mode ──────────────────────
if [ -n "${USENET_SERVERS:-}" ] || [ -n "${USENET_HOST:-}" ]; then
  echo "[openmedia] Legacy ENV mode — skipping config-pull"
  exit 0
fi

# ── Validate required bootstrap vars ─────────────────────────────
MISSING=""
for var in API_BASE_URL SERVICE_TOKEN JOB_ID; do
  if [ -z "${!var:-}" ]; then
    MISSING="${MISSING} ${var}"
  fi
done

if [ -n "${MISSING}" ]; then
  echo "[openmedia] ERROR: Missing required bootstrap vars:${MISSING}"
  echo "[openmedia] Cannot fetch config from API — aborting"
  exit 1
fi

# ── Fetch bootstrap config from API ──────────────────────────────
BOOTSTRAP_URL="${API_BASE_URL}/service/jobs/${JOB_ID}/bootstrap"
echo "[openmedia] Fetching config from ${BOOTSTRAP_URL}"

MAX_ATTEMPTS=3
RETRY_DELAY=5
ATTEMPT=0
RESPONSE=""
HTTP_STATUS=""

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[openmedia] Bootstrap attempt ${ATTEMPT}/${MAX_ATTEMPTS}..."

  # Capture response body and HTTP status separately
  RESPONSE=$(curl -sf -w "\n%{http_code}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Accept: application/json" \
    "${BOOTSTRAP_URL}" 2>/dev/null) && {
    HTTP_STATUS=$(echo "${RESPONSE}" | tail -1)
    RESPONSE=$(echo "${RESPONSE}" | sed '$d')

    if [ "${HTTP_STATUS}" = "200" ]; then
      echo "[openmedia] Bootstrap API responded 200 OK"
      break
    fi

    echo "[openmedia] ERROR: Bootstrap API returned HTTP ${HTTP_STATUS}"
    echo "[openmedia] Response: ${RESPONSE}"
  } || {
    echo "[openmedia] ERROR: curl failed (API unreachable or connection error)"
    HTTP_STATUS="000"
  }

  if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
    echo "[openmedia] Retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

if [ "${HTTP_STATUS}" != "200" ] || [ -z "${RESPONSE}" ]; then
  echo "[openmedia] FATAL: Bootstrap failed after ${MAX_ATTEMPTS} attempts (last HTTP: ${HTTP_STATUS})"
  echo "[openmedia] Container cannot start without config — aborting"
  exit 1
fi

# ── Parse JSON response and extract config ───────────────────────
# Response shape:
#   { "job": { "id", "hash", "nzbFileId", ... },
#     "config": { "s3AccessKey", "s3SecretKey", "s3Endpoint", "s3Bucket",
#                 "s3Region", "nzbServiceUrl", "usenetServers": [...] } }

JOB_HASH=$(echo "${RESPONSE}" | jq -r '.job.hash')
NZB_SERVICE_URL=$(echo "${RESPONSE}" | jq -r '.config.nzbServiceUrl')
NZB_FILE_ID=$(echo "${RESPONSE}" | jq -r '.job.nzbFileId')
S3_ACCESS_KEY=$(echo "${RESPONSE}" | jq -r '.config.s3AccessKey')
S3_SECRET_KEY=$(echo "${RESPONSE}" | jq -r '.config.s3SecretKey')
S3_ENDPOINT=$(echo "${RESPONSE}" | jq -r '.config.s3Endpoint')
S3_BUCKET=$(echo "${RESPONSE}" | jq -r '.config.s3Bucket')
S3_REGION=$(echo "${RESPONSE}" | jq -r '.config.s3Region')
USENET_SERVERS=$(echo "${RESPONSE}" | jq -c '.config.usenetServers')

# Build the NZB download URL from service URL + hash
NZB_URL="${NZB_SERVICE_URL}/nzb/${JOB_HASH}.nzb"

# Validate critical fields
for var_name in JOB_HASH S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET; do
  eval "val=\${${var_name}}"
  if [ -z "${val}" ] || [ "${val}" = "null" ]; then
    echo "[openmedia] FATAL: Bootstrap response missing required field: ${var_name}"
    echo "[openmedia] Raw response: ${RESPONSE}"
    exit 1
  fi
done

if [ "${USENET_SERVERS}" = "null" ] || [ "${USENET_SERVERS}" = "[]" ]; then
  echo "[openmedia] FATAL: Bootstrap response has no usenet servers"
  exit 1
fi

# ── Write env file for downstream scripts ────────────────────────
echo "[openmedia] Writing config to ${API_ENV_FILE}"
mkdir -p "$(dirname "${API_ENV_FILE}")"
(umask 077; cat > "${API_ENV_FILE}" << EOF
export JOB_HASH="${JOB_HASH}"
export NZB_URL="${NZB_URL}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY}"
export S3_SECRET_KEY="${S3_SECRET_KEY}"
export S3_ENDPOINT="${S3_ENDPOINT}"
export S3_BUCKET="${S3_BUCKET}"
export S3_REGION="${S3_REGION}"
export USENET_SERVERS='${USENET_SERVERS}'
EOF
)

echo "[openmedia] ✅ Config-pull complete"
echo "[openmedia]   Job Hash:  ${JOB_HASH:0:16}..."
echo "[openmedia]   NZB URL:   ${NZB_URL}"
echo "[openmedia]   S3 Bucket: ${S3_BUCKET}"
USENET_COUNT=$(echo "${USENET_SERVERS}" | jq 'length')
echo "[openmedia]   Usenet:    ${USENET_COUNT} server(s)"
