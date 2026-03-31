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
#   OPENMEDIA_S3_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
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

# ── Signal uploading status ─────────────────────────────────────
echo "[post-process] Signaling status: uploading"
report_status "uploading" '{"status":"uploading","progress":75}'

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

# ── Upload to S3 ────────────────────────────────────────────────
echo "[post-process] Uploading to s3://${S3_BUCKET}/${S3_KEY}..."

report_status "uploading" '{"status":"uploading","progress":80}'

UPLOAD_START=$(date +%s)

if aws s3 cp "${VIDEO_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
    --endpoint-url "${S3_ENDPOINT}" \
    --region "${S3_REGION}" \
    --no-progress; then

  UPLOAD_END=$(date +%s)
  UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))
  echo "[post-process] ✅ Upload complete (${UPLOAD_DURATION}s)"
else
  echo "[post-process] ERROR: S3 upload failed"
  report_status "failed" '{"status":"failed","error":"S3 Upload fehlgeschlagen"}'
  exit 1
fi

# ── Signal completed to API ─────────────────────────────────────
echo "[post-process] Signaling status: completed"

report_status "completed" \
  "{\"status\":\"completed\",\"s3Key\":\"${S3_KEY}\",\"s3Bucket\":\"${S3_BUCKET}\",\"fileExtension\":\"${FILE_EXT_LOWER}\",\"progress\":100}"

echo "========================================"
echo "[post-process] ✅ Done!"
echo "[post-process] Hash:     ${HASH:0:16}..."
echo "[post-process] S3:       s3://${S3_BUCKET}/${S3_KEY}"
echo "[post-process] Duration: ${UPLOAD_DURATION}s upload"
echo "========================================"

exit 0
