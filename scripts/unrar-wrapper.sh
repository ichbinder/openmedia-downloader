#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# unrar → 7zz-rar wrapper for multi-threaded RAR extraction
#
# SABnzbd calls unrar with specific flags. This wrapper translates
# the most common unrar commands to 7zz-rar equivalents while using
# all available CPU cores for extraction.
#
# Common SABnzbd invocations:
#   unrar x -o- -idp -p<pass> archive.rar /dest/
#   unrar x -o- -ai -idp archive.rar /dest/
#   unrar e -o- archive.rar /dest/
#   unrar l archive.rar
#   unrar vb archive.rar
#   unrar vt archive.rar
# ─────────────────────────────────────────────────────────────────

THREADS=$(nproc 2>/dev/null || echo 4)

# Parse the unrar command
CMD="${1:-}"
shift 2>/dev/null || true

case "${CMD}" in
  x|e)
    # Extract command — translate to 7zz
    PASSWORD=""
    ARCHIVE=""
    DEST=""
    OVERWRITE="-aoa"  # default: auto-rename (safe)

    for arg in "$@"; do
      case "${arg}" in
        -p*)
          # Password: -pSECRET → -pSECRET (same syntax in 7zz)
          PASSWORD="${arg}"
          ;;
        -o+)
          OVERWRITE="-aoa"  # overwrite all
          ;;
        -o-)
          OVERWRITE="-aos"  # skip existing (closest to unrar's -o-)
          ;;
        -ai|-idp|-idc|-idq|-y)
          # Ignore: -ai (ignore file attributes), -idp (disable percentage),
          # -idc (disable copyright), -idq (quiet), -y (yes to all)
          ;;
        -*)
          # Unknown flag — ignore
          ;;
        *)
          if [ -z "${ARCHIVE}" ]; then
            ARCHIVE="${arg}"
          else
            DEST="${arg}"
          fi
          ;;
      esac
    done

    if [ -z "${ARCHIVE}" ]; then
      echo "ERROR: No archive specified"
      exit 2
    fi

    # Build 7zz-rar command
    SEVENZ_ARGS=()
    SEVENZ_ARGS+=("x")                # extract with paths
    SEVENZ_ARGS+=("-mmt=${THREADS}")   # multi-threaded
    SEVENZ_ARGS+=("${OVERWRITE}")      # overwrite mode
    SEVENZ_ARGS+=("-bb0")              # minimal output
    SEVENZ_ARGS+=("-bd")               # disable progress indicator
    SEVENZ_ARGS+=("-y")                # yes to all queries

    if [ -n "${PASSWORD}" ]; then
      SEVENZ_ARGS+=("${PASSWORD}")
    fi

    SEVENZ_ARGS+=("${ARCHIVE}")

    if [ -n "${DEST}" ]; then
      # 7zz uses -o<dir> instead of trailing dir
      # Remove trailing slash for consistency
      DEST="${DEST%/}"
      SEVENZ_ARGS+=("-o${DEST}")
    fi

    echo "[7zz-rar] Extracting with ${THREADS} threads: $(basename "${ARCHIVE}")"
    exec /usr/local/bin/7zz-rar "${SEVENZ_ARGS[@]}"
    ;;

  l|lt|la)
    # List archive — translate directly
    exec /usr/local/bin/7zz-rar l "$@"
    ;;

  v|vb|vt)
    # Verbose list — use 7zz list
    exec /usr/local/bin/7zz-rar l -slt "$@"
    ;;

  t)
    # Test archive
    exec /usr/local/bin/7zz-rar t -mmt="${THREADS}" "$@"
    ;;

  *)
    # Fallback to real unrar for unknown commands
    exec /usr/bin/unrar.real "${CMD}" "$@"
    ;;
esac
