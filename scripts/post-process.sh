#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# SABnzbd Post-Processing Script for openmedia
#
# Called by SABnzbd after a download completes (repair + unpack).
#
# Parameters from SABnzbd:
#   $1 = Final directory of the job (full path)
#   $2 = Original NZB filename
#   $3 = Clean job name (= JOB_HASH, because we set nzbname=hash)
#   $4 = Indexer report number
#   $5 = Category
#   $6 = Newsgroup
#   $7 = Post-processing status (0=OK)
#
# Environment from SABnzbd:
#   SAB_FINAL_NAME  = Clean job name (= JOB_HASH)
#   SAB_COMPLETE_DIR = Full path to output directory
#   SAB_PP_STATUS   = Post-processing status
#
# Our custom env vars (from /opt/openmedia/.env):
#   OPENMEDIA_JOB_ID, OPENMEDIA_JOB_HASH, OPENMEDIA_API_BASE_URL,
#   OPENMEDIA_SERVICE_TOKEN, OPENMEDIA_S3_ENDPOINT, OPENMEDIA_S3_BUCKET,
#   OPENMEDIA_S3_REGION, S3_ACCESS_KEY, S3_SECRET_KEY
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# Source our env vars (SABnzbd may not pass parent env to scripts)
if [ -f /opt/openmedia/.env ]; then
  set -a
  source /opt/openmedia/.env
  set +a
  # Delete env file after reading — secrets no longer needed on disk
  rm -f /opt/openmedia/.env
fi

FINAL_DIR="${1:-${SAB_COMPLETE_DIR:-}}"
HASH="${3:-${SAB_FINAL_NAME:-${OPENMEDIA_JOB_HASH:-}}}"
PP_STATUS="${7:-${SAB_PP_STATUS:-0}}"
JOB_ID="${OPENMEDIA_JOB_ID:-}"
API_URL="${OPENMEDIA_API_BASE_URL:-}"
TOKEN="${OPENMEDIA_SERVICE_TOKEN:-}"
S3_ENDPOINT="${OPENMEDIA_S3_ENDPOINT:-}"
S3_BUCKET="${OPENMEDIA_S3_BUCKET:-}"
S3_REGION="${OPENMEDIA_S3_REGION:-hel1}"
S3_ACCESS_KEY="${OPENMEDIA_S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${OPENMEDIA_S3_SECRET_KEY:-}"

echo "========================================"
echo "[post-process] Starting"
echo "[post-process] Directory: ${FINAL_DIR}"
echo "[post-process] Hash:      ${HASH:0:16}..."
echo "[post-process] PP Status: ${PP_STATUS}"
echo "[post-process] Job ID:    ${JOB_ID}"
echo "========================================"

# ── Helper: report status to API ────────────────────────────────
report_status() {
  local status="$1"
  local body="$2"
  if [ -n "${API_URL}" ] && [ -n "${TOKEN}" ] && [ -n "${JOB_ID}" ]; then
    curl -sf -X PATCH "${API_URL}/downloads/jobs/${JOB_ID}/status" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${body}" || echo "[post-process] WARNING: API callback failed for status ${status}"
  fi
}

# ── Check post-processing status ────────────────────────────────
if [ "${PP_STATUS}" != "0" ]; then
  echo "[post-process] ERROR: SABnzbd post-processing failed (status: ${PP_STATUS})"
  report_status "failed" "{\"status\":\"failed\",\"error\":\"SABnzbd post-processing failed (status ${PP_STATUS})\"}"
  exit 1
fi

# ── Validate required vars ──────────────────────────────────────
if [ -z "${HASH}" ]; then
  echo "[post-process] ERROR: No hash available"
  report_status "failed" '{"status":"failed","error":"No hash available in post-processing"}'
  exit 1
fi

if [ -z "${FINAL_DIR}" ] || [ ! -d "${FINAL_DIR}" ]; then
  echo "[post-process] ERROR: Final directory not found: ${FINAL_DIR}"
  report_status "failed" "{\"status\":\"failed\",\"error\":\"Output directory not found\"}"
  exit 1
fi

# ── Find video file ─────────────────────────────────────────────
echo "[post-process] Searching for video file in ${FINAL_DIR}..."

VIDEO_FILE=""
for ext in mkv mp4 avi m4v wmv; do
  FOUND=$(find "${FINAL_DIR}" -type f -iname "*.${ext}" -size +10M 2>/dev/null | sort -rn | head -1)
  if [ -n "${FOUND}" ]; then
    VIDEO_FILE="${FOUND}"
    break
  fi
done

if [ -z "${VIDEO_FILE}" ]; then
  echo "[post-process] ERROR: No video file found (>10MB) in ${FINAL_DIR}"
  echo "[post-process] Directory contents:"
  find "${FINAL_DIR}" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -20
  report_status "failed" '{"status":"failed","error":"Keine Videodatei gefunden nach dem Entpacken."}'
  exit 1
fi

FILE_SIZE=$(stat -c%s "${VIDEO_FILE}" 2>/dev/null || stat -f%z "${VIDEO_FILE}" 2>/dev/null || echo "unknown")
FILE_EXT=".${VIDEO_FILE##*.}"
FILE_EXT_LOWER=$(echo "${FILE_EXT}" | tr '[:upper:]' '[:lower:]')

echo "[post-process] Found: ${VIDEO_FILE}"
echo "[post-process] Size:  ${FILE_SIZE} bytes"
echo "[post-process] Ext:   ${FILE_EXT_LOWER}"

# ── Build S3 key ────────────────────────────────────────────────
S3_KEY="${HASH}/${HASH}${FILE_EXT_LOWER}"
echo "[post-process] S3 key: ${S3_KEY}"

# ── Prepare rclone config (needed for all uploads) ──────────────
RCLONE_CFG=$(mktemp /tmp/rclone-XXXXXX.conf)
trap 'rm -f "${RCLONE_CFG}"' EXIT
(umask 077; cat > "${RCLONE_CFG}" << RCFG
[s3]
type = s3
provider = Other
endpoint = ${S3_ENDPOINT}
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
region = ${S3_REGION}
RCFG
)

# Common rclone flags (array to avoid word-splitting issues)
RCLONE_OPTS=(--config "${RCLONE_CFG}" --s3-upload-concurrency 8 --s3-chunk-size 100M --s3-no-check-bucket --no-check-dest --log-level INFO)

# ── FFmpeg Remux: create browser-streamable MP4 ─────────────────
# Remuxes video (copy) + all audio tracks to AAC stereo in MP4 container.
# -ac 2: downmix to stereo (required for Safari iOS/Desktop compatibility)
# -threads: use all available CPUs for faster encoding
# Runs BEFORE upload so both files are ready for parallel upload.
STREAM_FILE=""
S3_STREAM_KEY=""

THREADS=$(nproc 2>/dev/null || echo 4)
echo "[post-process] Starting FFmpeg remux to MP4 (${THREADS} threads, stereo downmix)..."
STREAM_FILE="${FINAL_DIR}/${HASH}_stream.mp4"
S3_STREAM_KEY="${HASH}/${HASH}_stream.mp4"

REMUX_START=$(date +%s)

if ffmpeg -y -i "${VIDEO_FILE}" \
    -c:v copy \
    -c:a aac -ac 2 -b:a 256k \
    -threads "${THREADS}" \
    -map 0:v:0 \
    -map 0:a \
    -movflags +faststart \
    -loglevel warning \
    "${STREAM_FILE}" 2>&1; then

  REMUX_END=$(date +%s)
  REMUX_DURATION=$((REMUX_END - REMUX_START))
  STREAM_SIZE=$(stat -c%s "${STREAM_FILE}" 2>/dev/null || stat -f%z "${STREAM_FILE}" 2>/dev/null || echo "unknown")
  echo "[post-process] ✅ Remux complete (${REMUX_DURATION}s)"
  echo "[post-process] Stream size: ${STREAM_SIZE} bytes"
else
  echo "[post-process] ⚠️ FFmpeg remux FAILED — continuing with original only"
  STREAM_FILE=""
  S3_STREAM_KEY=""
fi

# ── Upload both files to S3 in parallel ─────────────────────────
# Both files upload simultaneously with 8 concurrency each.
# CPU is idle during upload (~100% vs 400% max), two rclone processes fit easily.
# This gives ~250 Mbps combined bandwidth vs ~150 Mbps sequential.
UPLOAD_START=$(date +%s)

report_status "uploading" '{"status":"uploading","progress":80}'

echo "[post-process] Uploading original to s3://${S3_BUCKET}/${S3_KEY} (${FILE_SIZE} bytes)..."

# Start stream upload in background (if remux succeeded)
STREAM_PID=""
if [ -n "${STREAM_FILE}" ] && [ -f "${STREAM_FILE}" ]; then
  echo "[post-process] Uploading stream to s3://${S3_BUCKET}/${S3_STREAM_KEY} (parallel)..."
  rclone copyto "${STREAM_FILE}" "s3:${S3_BUCKET}/${S3_STREAM_KEY}" "${RCLONE_OPTS[@]}" &
  STREAM_PID=$!
fi

# Original upload in foreground (must succeed)
if ! rclone copyto "${VIDEO_FILE}" "s3:${S3_BUCKET}/${S3_KEY}" "${RCLONE_OPTS[@]}"; then
  echo "[post-process] ERROR: S3 upload failed"
  report_status "failed" '{"status":"failed","error":"S3 Upload fehlgeschlagen"}'
  exit 1
fi

# Wait for stream upload if started
if [ -n "${STREAM_PID}" ]; then
  if wait "${STREAM_PID}"; then
    echo "[post-process] ✅ Stream upload complete"
  else
    echo "[post-process] ⚠️ Stream upload FAILED — original is still available"
    S3_STREAM_KEY=""
  fi
fi

UPLOAD_END=$(date +%s)
UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))

if [ "${UPLOAD_DURATION}" -gt 0 ] && [ "${FILE_SIZE}" != "unknown" ]; then
  SPEED_MBS=$(( FILE_SIZE / UPLOAD_DURATION / 1024 / 1024 ))
  echo "[post-process] ✅ Upload complete (${UPLOAD_DURATION}s, ~${SPEED_MBS} MB/s)"
else
  echo "[post-process] ✅ Upload complete (${UPLOAD_DURATION}s)"
fi

# ── Signal completed to API ─────────────────────────────────────
echo "[post-process] Signaling status: completed"

# Build the callback body — include s3StreamKey only if remux succeeded
CALLBACK_BODY="{\"status\":\"completed\",\"s3Key\":\"${S3_KEY}\",\"s3Bucket\":\"${S3_BUCKET}\",\"fileExtension\":\"${FILE_EXT_LOWER}\",\"progress\":100"
if [ -n "${S3_STREAM_KEY}" ]; then
  CALLBACK_BODY="${CALLBACK_BODY},\"s3StreamKey\":\"${S3_STREAM_KEY}\""
fi
CALLBACK_BODY="${CALLBACK_BODY}}"

report_status "completed" "${CALLBACK_BODY}"

echo "========================================"
echo "[post-process] ✅ Done!"
echo "[post-process] Hash:     ${HASH:0:16}..."
echo "[post-process] S3:       s3://${S3_BUCKET}/${S3_KEY}"
if [ -n "${S3_STREAM_KEY}" ]; then
echo "[post-process] Stream:   s3://${S3_BUCKET}/${S3_STREAM_KEY}"
fi
echo "[post-process] Duration: ${UPLOAD_DURATION}s (remux + upload pipelined)"
echo "========================================"

# Signal completion for submit-and-monitor.sh to trigger container shutdown.
# Post-process runs as abc (UID 911) and cannot stop s6 directly.
touch /tmp/openmedia-upload-done

exit 0
