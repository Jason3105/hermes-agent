#!/bin/bash
# =============================================================================
# Hermes Agent — Supabase State Sync Entrypoint
# =============================================================================
# Lifecycle:
#   1. Download state.db (+ optional .env) from Supabase Storage (skip on 404)
#   2. Start `hermes gateway run` in the foreground as a background process
#   3. Run a background loop that uploads state.db every $BACKUP_INTERVAL_MINS
#   4. Trap SIGTERM/SIGINT → final upload → clean shutdown
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Required environment variables
# ---------------------------------------------------------------------------
: "${SUPABASE_URL:?SUPABASE_URL must be set}"
: "${SUPABASE_SERVICE_KEY:?SUPABASE_SERVICE_KEY must be set}"
: "${SUPABASE_BUCKET:=hermes-state}"

# ---------------------------------------------------------------------------
# Optional / defaulted environment variables
# ---------------------------------------------------------------------------
HERMES_DATA_DIR="${HERMES_DATA_DIR:-/opt/data}"
STATE_DB_PATH="${HERMES_DATA_DIR}/state.db"
ENV_FILE_PATH="${HERMES_DATA_DIR}/.env"
CONFIG_FILE_PATH="${HERMES_DATA_DIR}/config.yaml"
BACKUP_INTERVAL_MINS="${BACKUP_INTERVAL_MINS:-5}"
BACKUP_INTERVAL_SECS=$(( BACKUP_INTERVAL_MINS * 60 ))

# Supabase Storage base URL for the bucket
STORAGE_BASE="${SUPABASE_URL}/storage/v1/object/${SUPABASE_BUCKET}"

# Common curl auth headers (service_role bypasses RLS)
AUTH_HEADERS=(
  -H "apikey: ${SUPABASE_SERVICE_KEY}"
  -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}"
)

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [INFO]  $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [WARN]  $*" >&2; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Function: download_from_supabase <remote_path> <local_path>
#   Returns 0 on success, 1 on 404 (first run), 2 on other errors
# ---------------------------------------------------------------------------
download_from_supabase() {
  local remote_path="$1"
  local local_path="$2"

  log "Attempting download: ${STORAGE_BASE}/${remote_path} → ${local_path}"

  HTTP_STATUS=$(curl -sSL \
    "${AUTH_HEADERS[@]}" \
    -w "%{http_code}" \
    -o "${local_path}.tmp" \
    "${STORAGE_BASE}/${remote_path}" 2>/dev/null || true)

  case "${HTTP_STATUS}" in
    200)
      mv "${local_path}.tmp" "${local_path}"
      log "Download successful: ${local_path}"
      return 0
      ;;
    404)
      rm -f "${local_path}.tmp"
      warn "Remote file not found (404) — first run or empty bucket. Skipping."
      return 1
      ;;
    *)
      rm -f "${local_path}.tmp"
      err "Download failed with HTTP status ${HTTP_STATUS} for ${remote_path}"
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Function: upload_to_supabase <local_path> <remote_path>
#   Uses x-upsert: true so the first upload creates and subsequent ones overwrite
# ---------------------------------------------------------------------------
upload_to_supabase() {
  local local_path="$1"
  local remote_path="$2"

  if [[ ! -f "${local_path}" ]]; then
    warn "Upload skipped — file does not exist: ${local_path}"
    return 0
  fi

  log "Uploading: ${local_path} → ${STORAGE_BASE}/${remote_path}"

  HTTP_STATUS=$(curl -sSL \
    -X POST \
    "${AUTH_HEADERS[@]}" \
    -H "x-upsert: true" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${local_path}" \
    -w "%{http_code}" \
    -o /dev/null \
    "${STORAGE_BASE}/${remote_path}" 2>/dev/null || true)

  if [[ "${HTTP_STATUS}" =~ ^2 ]]; then
    log "Upload successful (HTTP ${HTTP_STATUS}): ${remote_path}"
    return 0
  else
    err "Upload failed (HTTP ${HTTP_STATUS}): ${local_path} → ${remote_path}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Function: backup_state
#   Uploads all critical state files to Supabase Storage
# ---------------------------------------------------------------------------
backup_state() {
  log "=== Running state backup ==="
  upload_to_supabase "${STATE_DB_PATH}" "state.db" || true

  # config.yaml stores model selection, provider settings, and other
  # in-agent configuration set via `hermes model` or the dashboard.
  # Backing it up means model switches survive container restarts.
  if [[ -f "${CONFIG_FILE_PATH}" ]]; then
    upload_to_supabase "${CONFIG_FILE_PATH}" "config.yaml" || true
  fi

  # Upload .env only if it exists (contains platform tokens such as Telegram)
  if [[ -f "${ENV_FILE_PATH}" ]]; then
    upload_to_supabase "${ENV_FILE_PATH}" ".env" || true
  fi
  log "=== Backup complete ==="
}

# ---------------------------------------------------------------------------
# Function: shutdown_handler
#   Called on SIGTERM or SIGINT — perform a final backup then exit
# ---------------------------------------------------------------------------
HERMES_PID=""
shutdown_handler() {
  log "Received shutdown signal. Performing final state backup..."
  backup_state

  if [[ -n "${HERMES_PID}" ]] && kill -0 "${HERMES_PID}" 2>/dev/null; then
    log "Sending SIGTERM to Hermes gateway (PID ${HERMES_PID})..."
    kill -SIGTERM "${HERMES_PID}" 2>/dev/null || true
    # Give Hermes up to 30 seconds to shut down gracefully
    local count=0
    while kill -0 "${HERMES_PID}" 2>/dev/null && (( count < 30 )); do
      sleep 1
      (( count++ ))
    done
    if kill -0 "${HERMES_PID}" 2>/dev/null; then
      warn "Hermes did not exit in 30s — sending SIGKILL."
      kill -SIGKILL "${HERMES_PID}" 2>/dev/null || true
    fi
  fi

  log "Shutdown complete."
  exit 0
}

# Register the shutdown handler for both SIGTERM (Render) and SIGINT (Ctrl+C)
trap 'shutdown_handler' SIGTERM SIGINT

# ===========================================================================
# STEP 1 — Restore state from Supabase on startup
# ===========================================================================
log "============================================================"
log " Hermes Agent — Supabase State Sync Entrypoint Starting"
log "============================================================"
log "Data dir     : ${HERMES_DATA_DIR}"
log "Bucket       : ${SUPABASE_BUCKET}"
log "Backup every : ${BACKUP_INTERVAL_MINS} min(s)"

# Ensure the data directory exists with correct permissions
mkdir -p "${HERMES_DATA_DIR}"

log "--- Restoring state from Supabase Storage ---"
download_from_supabase "state.db"    "${STATE_DB_PATH}"    || true
download_from_supabase "config.yaml" "${CONFIG_FILE_PATH}" || true
download_from_supabase ".env"        "${ENV_FILE_PATH}"    || true

# ===========================================================================
# STEP 2 — Start Hermes Gateway in the background
# ===========================================================================
log "--- Starting Hermes gateway ---"

# Source the .env file if it was downloaded (gives Hermes its platform tokens)
if [[ -f "${ENV_FILE_PATH}" ]]; then
  log "Loading .env from ${ENV_FILE_PATH}"
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE_PATH}"; set +a
fi

# Start the gateway in the foreground but backgrounded via & so we can
# manage the backup loop alongside it. Hermes is configured via env vars
# (API_SERVER_HOST, API_SERVER_PORT, API_SERVER_KEY, etc.) already set
# in the Render environment.
hermes gateway run &
HERMES_PID=$!
log "Hermes gateway started (PID ${HERMES_PID})"

# Wait briefly for the gateway to initialise before starting the backup loop
sleep 10

# ===========================================================================
# STEP 3 — Backup loop
# ===========================================================================
log "--- Starting periodic backup loop (every ${BACKUP_INTERVAL_MINS} min) ---"

while true; do
  # Check if Hermes is still alive
  if ! kill -0 "${HERMES_PID}" 2>/dev/null; then
    err "Hermes gateway process (PID ${HERMES_PID}) has exited unexpectedly!"
    # Perform one final backup before the container exits
    backup_state
    exit 1
  fi

  sleep "${BACKUP_INTERVAL_SECS}" &
  SLEEP_PID=$!

  # wait -n returns when any background job completes (bash 4.3+)
  # This allows the trap to fire immediately on SIGTERM without
  # waiting for the full sleep interval to expire.
  wait -n "${SLEEP_PID}" "${HERMES_PID}" 2>/dev/null || true

  # Re-check that both the sleep AND Hermes are still running
  if ! kill -0 "${HERMES_PID}" 2>/dev/null; then
    err "Hermes gateway exited during backup wait. Performing final backup."
    backup_state
    exit 1
  fi

  # If sleep finished naturally, run the periodic backup
  if ! kill -0 "${SLEEP_PID}" 2>/dev/null; then
    backup_state
  fi
done
