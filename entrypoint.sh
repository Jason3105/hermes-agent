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
# Exit on error
set -euo pipefail

# Force Python stdout/stderr to be unbuffered so logs are instantly visible on Render
export PYTHONUNBUFFERED=1

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

  log "Attempting download: ${SUPABASE_URL}/storage/v1/object/authenticated/${SUPABASE_BUCKET}/${remote_path} → ${local_path}"

  HTTP_STATUS=$(curl -sSL \
    "${AUTH_HEADERS[@]}" \
    -w "%{http_code}" \
    -o "${local_path}.tmp" \
    "${SUPABASE_URL}/storage/v1/object/authenticated/${SUPABASE_BUCKET}/${remote_path}" 2>/dev/null || true)

  case "${HTTP_STATUS}" in
    200)
      mv "${local_path}.tmp" "${local_path}"
      log "Download successful: ${local_path}"
      return 0
      ;;
    404)
      rm -f "${local_path}.tmp"
      warn "Remote file ${remote_path} not found (404) — skipping."
      return 1
      ;;
    400)
      if grep -qE '"error":"Key not found"|"message":"The resource was not found"|"Key not found"' "${local_path}.tmp" 2>/dev/null; then
        rm -f "${local_path}.tmp"
        warn "Remote file ${remote_path} not found (400: Key not found) — skipping."
        return 1
      else
        rm -f "${local_path}.tmp"
        err "Download failed with HTTP status 400 for ${remote_path}"
        return 2
      fi
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

  # Upload Google token files if they exist
  if [[ -f "${HERMES_DATA_DIR}/google_token.json" ]]; then
    upload_to_supabase "${HERMES_DATA_DIR}/google_token.json" "google_token.json" || true
  fi
  if [[ -f "${HERMES_DATA_DIR}/google_client_secret.json" ]]; then
    upload_to_supabase "${HERMES_DATA_DIR}/google_client_secret.json" "google_client_secret.json" || true
  fi

  # Upload skills directory if it exists
  if [[ -d "${HERMES_DATA_DIR}/skills" ]]; then
    tar -czf "${HERMES_DATA_DIR}/.skills-backup.tar.gz" -C "${HERMES_DATA_DIR}" skills
    upload_to_supabase "${HERMES_DATA_DIR}/.skills-backup.tar.gz" "skills.tar.gz" || true
    rm -f "${HERMES_DATA_DIR}/.skills-backup.tar.gz"
  fi
  log "=== Backup complete ==="
}

# ---------------------------------------------------------------------------
# Function: shutdown_handler
#   Called on SIGTERM or SIGINT — perform a final backup then exit
# ---------------------------------------------------------------------------
HERMES_PID=""
DASHBOARD_PID=""
CADDY_PID=""
shutdown_handler() {
  log "Received shutdown signal. Performing final state backup..."
  backup_state

  # Terminate Caddy
  if [[ -n "${CADDY_PID}" ]] && kill -0 "${CADDY_PID}" 2>/dev/null; then
    log "Stopping Caddy proxy (PID ${CADDY_PID})..."
    kill -SIGTERM "${CADDY_PID}" 2>/dev/null || true
  fi

  # Terminate Dashboard
  if [[ -n "${DASHBOARD_PID}" ]] && kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
    log "Stopping Hermes Web Dashboard (PID ${DASHBOARD_PID})..."
    kill -SIGTERM "${DASHBOARD_PID}" 2>/dev/null || true
  fi

  # Terminate Gateway
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

# --- Restore skills from Supabase (idempotent) ---
SKILLS_RESTORE_TMP="${HERMES_DATA_DIR}/.skills-restored.tar.gz"
if download_from_supabase "skills.tar.gz" "${SKILLS_RESTORE_TMP}"; then
  mkdir -p "${HERMES_DATA_DIR}/skills" "${HERMES_DATA_DIR}/.cache"
  if tar -tzf "${SKILLS_RESTORE_TMP}" 2>/dev/null | grep -q "SKILL.md"; then
    tar -xzf "${SKILLS_RESTORE_TMP}" -C "${HERMES_DATA_DIR}" 2>/dev/null
    cp "${SKILLS_RESTORE_TMP}" "${HERMES_DATA_DIR}/.cache/skills.tar.gz"
    log "Skills restored from Supabase."
  else
    warn "skills.tar.gz from Supabase contained no SKILL.md — skipping."
  fi
  rm -f "${SKILLS_RESTORE_TMP}"
# --- Restore Google OAuth tokens from Supabase ---
if download_from_supabase "google_token.json" "${HERMES_DATA_DIR}/google_token.json"; then
  log "Google token restored from Supabase."
fi
if download_from_supabase "google_client_secret.json" "${HERMES_DATA_DIR}/google_client_secret.json"; then
  log "Google client secret restored from Supabase."
fi

# Ensure files are fully readable and writable by whatever user Hermes drops to
chmod -R 777 "${HERMES_DATA_DIR}" || true

# If config.yaml is missing (first run), generate a default to prevent Hermes
# from defaulting to OpenAI and crashing due to a missing OpenAI key.
if [[ ! -f "${CONFIG_FILE_PATH}" ]]; then
  log "No config.yaml found — generating default configuration."
  cat <<'EOF' > "${CONFIG_FILE_PATH}"
model:
  provider: "openrouter"
  default: "openai/gpt-4o"
EOF
fi

# Clean up duplicate custom groq provider and ensure github provider exists in config.yaml
if [[ -f "${CONFIG_FILE_PATH}" ]]; then
  log "Updating custom provider registrations in config.yaml..."
  python3 -c '
import yaml, sys
path = sys.argv[1]
try:
    with open(path, "r") as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    cfg = {}
changed = False
if "custom_providers" not in cfg:
    cfg["custom_providers"] = []
    changed = True

# Filter out groq (since Hermes natively supports Groq now)
before = len(cfg["custom_providers"])
cfg["custom_providers"] = [p for p in cfg["custom_providers"] if p.get("name") != "groq"]
if len(cfg["custom_providers"]) < before:
    changed = True

# Register github models endpoint if missing
if not any(p.get("name") == "github" for p in cfg["custom_providers"]):
    cfg["custom_providers"].append({
        "name": "github",
        "base_url": "https://models.inference.ai.azure.com",
        "key_env": "GITHUB_TOKEN"
    })
    changed = True

if not cfg["custom_providers"]:
    cfg.pop("custom_providers")

# Remove stale max_tokens override so Hermes uses the model default
if "model" in cfg and "max_tokens" in cfg["model"]:
    cfg["model"].pop("max_tokens")
    changed = True

# Configure auxiliary vision provider to prevent 'No LLM provider configured for task=vision provider=auto' errors
if "auxiliary" not in cfg:
    cfg["auxiliary"] = {}
    changed = True

vision_cfg = cfg["auxiliary"].get("vision", {})
if not vision_cfg or vision_cfg.get("provider") == "auto" or not vision_cfg.get("provider"):
    model_provider = cfg.get("model", {}).get("provider", "openrouter")
    if model_provider == "openrouter":
        cfg["auxiliary"]["vision"] = {
            "provider": "openrouter",
            "model": "google/gemini-2.5-flash:free"
        }
        changed = True
    elif model_provider in ("gemini", "google"):
        cfg["auxiliary"]["vision"] = {
            "provider": "gemini",
            "model": "gemini-2.5-flash"
        }
        changed = True
    elif model_provider == "github" or model_provider == "custom:github":
        cfg["auxiliary"]["vision"] = {
            "provider": "github",
            "model": "gpt-4o"
        }
        changed = True
    elif model_provider:
        cfg["auxiliary"]["vision"] = {
            "provider": model_provider,
            "model": "auto"
        }
        changed = True

if changed:
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f)
' "${CONFIG_FILE_PATH}" || true
fi

# Ensure correct permissions on config
chmod 777 "${CONFIG_FILE_PATH}" || true

# ===========================================================================
# STEP 2 — Configure and Start Gateway, Dashboard, and Caddy Proxy
# ===========================================================================

if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
  # Configure Dashboard Basic Auth environment variables
  export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-admin}"
  if [[ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]]; then
    export HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 16)
  fi

  # Generate the bcrypt hash of the password for Caddy basic_auth
  if [[ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]]; then
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(openssl rand -hex 8)
    log "------------------------------------------------------------"
    log " DASHBOARD PASSWORD GENERATED: ${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD}"
    log " Username: ${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}"
    log " Please save these credentials to access your dashboard!"
    log "------------------------------------------------------------"
  fi
  # Generate bcrypt hash (Caddy requires hashed passwords for basic_auth)
  export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$(caddy hash-password --plaintext "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD}")
fi

# When dashboard is disabled, Hermes binds directly to the public port (no Caddy needed)
# When dashboard is enabled, Caddy is the public face and Hermes stays on localhost
if [[ "${DISABLE_DASHBOARD:-}" == "true" ]]; then
  export API_SERVER_HOST="0.0.0.0"
  export API_SERVER_PORT="${PORT:-8642}"
else
  export API_SERVER_HOST="127.0.0.1"
  export API_SERVER_PORT="8642"
fi
export API_SERVER_ENABLED="true"

log "--- Starting Hermes gateway ---"

# Log which key env vars are present — values are NEVER printed, only SET/MISSING
_check_env() { local name="$1" val="$2"; if [[ -n "${val}" ]]; then log "Env check — ${name}: SET"; else log "Env check — ${name}: MISSING"; fi; }
_check_env "OPENROUTER_API_KEY " "${OPENROUTER_API_KEY:-}"
_check_env "GROQ_API_KEY       " "${GROQ_API_KEY:-}"
_check_env "GEMINI_API_KEY     " "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
_check_env "GITHUB_TOKEN       " "${GITHUB_TOKEN:-}"
_check_env "API_SERVER_KEY     " "${API_SERVER_KEY:-}"
_check_env "TELEGRAM_BOT_TOKEN " "${TELEGRAM_BOT_TOKEN:-}"
log "Env check — API_SERVER_ENABLED  : ${API_SERVER_ENABLED:-not set}"
log "Env check — API_SERVER_HOST     : ${API_SERVER_HOST:-not set}"
log "Env check — API_SERVER_PORT     : ${API_SERVER_PORT:-not set}"

# Source the .env file if it was downloaded (gives Hermes its platform tokens)
if [[ -f "${ENV_FILE_PATH}" ]]; then
  log "Loading .env from ${ENV_FILE_PATH}"
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE_PATH}"; set +a
fi

# Start the gateway — forward stdout/stderr to PID 1
hermes gateway run > /proc/1/fd/1 2>&1 &
HERMES_PID=$!
log "Hermes gateway started (PID ${HERMES_PID})"

# Start the web dashboard (binds internally to localhost:9119)
DASHBOARD_PID=""
if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
  log "--- Starting Hermes Web Dashboard ---"
  hermes dashboard --port 9119 --host 127.0.0.1 --no-open > /proc/1/fd/1 2>&1 &
  DASHBOARD_PID=$!
  log "Hermes Web Dashboard started (PID ${DASHBOARD_PID})"
else
  log "Hermes Web Dashboard is disabled via DISABLE_DASHBOARD=true"
fi

# Start Caddy reverse proxy (only needed when dashboard is enabled)
CADDY_PID=""
if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
  PUBLIC_PORT="${PORT:-8642}"
  log "--- Starting Caddy Reverse Proxy on port ${PUBLIC_PORT} ---"
cat <<EOF > /tmp/Caddyfile
{
    admin off
}

:${PUBLIC_PORT} {
    # Static health check response to keep Render happy even if Python is busy
    respond /health "OK" 200

    # Route API requests to the gateway (no auth)
    reverse_proxy /v1/* 127.0.0.1:8642 {
        header_up Host {upstream_hostport}
    }

    # Match everything except API, health check, and WebSocket paths for dashboard auth
    @dashboard {
        not path /v1/* /health /api/*
    }

    # Authenticate dashboard static routes
    basic_auth @dashboard {
        "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}" "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH}"
    }

    # Route all other traffic to the web dashboard (includes /api/*)
    reverse_proxy /* 127.0.0.1:9119 {
        header_up Host {upstream_hostport}
    }
}
EOF
  caddy run --config /tmp/Caddyfile > /proc/1/fd/1 2>&1 &
  CADDY_PID=$!
  log "Caddy proxy started (PID ${CADDY_PID})"
else
  log "Caddy proxy skipped — Hermes Gateway is bound directly to 0.0.0.0:${PORT:-8642}"
fi

# Early crash detection: wait 5 s then check if all running processes are healthy
sleep 5
if ! kill -0 "${HERMES_PID}" 2>/dev/null; then
  wait "${HERMES_PID}" 2>/dev/null; EXIT_CODE=$?
  err "Hermes gateway crashed within 5 seconds (exit code ${EXIT_CODE})."
  backup_state
  exit 1
fi
if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
  if ! kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
    wait "${DASHBOARD_PID}" 2>/dev/null; EXIT_CODE=$?
    err "Hermes Web Dashboard crashed within 5 seconds (exit code ${EXIT_CODE})."
    backup_state
    exit 1
  fi
fi
if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
  if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
    wait "${CADDY_PID}" 2>/dev/null; EXIT_CODE=$?
    err "Caddy proxy crashed within 5 seconds (exit code ${EXIT_CODE})."
    backup_state
    exit 1
  fi
fi
log "All services are healthy — continuing."

# Additional buffer before the backup loop starts
sleep 5

# ===========================================================================
# STEP 3 — Backup loop
# ===========================================================================
log "--- Starting periodic backup loop (every ${BACKUP_INTERVAL_MINS} min) ---"

while true; do
  # Check if Hermes Gateway is still alive
  if ! kill -0 "${HERMES_PID}" 2>/dev/null; then
    err "Hermes gateway process (PID ${HERMES_PID}) has exited unexpectedly!"
    backup_state
    exit 1
  fi

  # Check if Hermes Web Dashboard is still alive
  if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
    if ! kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
      err "Hermes Web Dashboard process (PID ${DASHBOARD_PID}) has exited unexpectedly!"
      backup_state
      exit 1
    fi
  fi

  # Check if Caddy Proxy is still alive
  if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
    if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
      err "Caddy proxy process (PID ${CADDY_PID}) has exited unexpectedly!"
      backup_state
      exit 1
    fi
  fi

  sleep "${BACKUP_INTERVAL_SECS}" &
  SLEEP_PID=$!

  # Build list of PIDs to wait for
  WAIT_PIDS=("${SLEEP_PID}" "${HERMES_PID}")
  if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
    WAIT_PIDS+=("${DASHBOARD_PID}" "${CADDY_PID}")
  fi

  # wait -n returns when any background job completes (bash 4.3+)
  wait -n "${WAIT_PIDS[@]}" 2>/dev/null || true

  # Re-check Gateway
  if ! kill -0 "${HERMES_PID}" 2>/dev/null; then
    err "Hermes gateway exited during backup wait. Performing final backup."
    backup_state
    exit 1
  fi

  # Re-check Dashboard
  if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
    if ! kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
      err "Hermes Web Dashboard exited during backup wait. Performing final backup."
      backup_state
      exit 1
    fi
  fi

  # Re-check Caddy
  if [[ "${DISABLE_DASHBOARD:-}" != "true" ]]; then
    if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
      err "Caddy proxy exited during backup wait. Performing final backup."
      backup_state
      exit 1
    fi
  fi

  # If sleep finished naturally, run the periodic backup
  if ! kill -0 "${SLEEP_PID}" 2>/dev/null; then
    backup_state
  fi
done
