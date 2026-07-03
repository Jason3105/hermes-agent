# syntax=docker/dockerfile:1
# =============================================================================
# Hermes Agent — Custom Image with Supabase State Sync
# =============================================================================
# Inherits from the official Hermes Agent image and adds:
#   - curl (for Supabase Storage REST API calls)
#   - A custom entrypoint that restores/backs up state around the gateway
# =============================================================================

FROM ghcr.io/nousresearch/hermes-agent:latest

# Install curl (needed for Supabase Storage REST calls).
# The base image is Debian/Ubuntu-based; update the apt cache and clean up
# in the same RUN layer to keep the image layer size small.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Copy the entrypoint wrapper into the image root.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---------------------------------------------------------------------------
# Environment variable defaults (all overridable via Render env vars)
# ---------------------------------------------------------------------------

# Where Hermes stores its state database and config
ENV HERMES_DATA_DIR=/opt/data

# Supabase Storage bucket name (override if you used a different name)
ENV SUPABASE_BUCKET=hermes-state

# How often (in minutes) to push the SQLite DB to Supabase Storage
ENV BACKUP_INTERVAL_MINS=5

# Bind the API server to all interfaces so Render can route traffic to it.
# The default is 127.0.0.1 which would make the service unreachable externally.
ENV API_SERVER_HOST=0.0.0.0
ENV API_SERVER_ENABLED=true

# Default gateway port — must match the port you expose in Render.
ENV API_SERVER_PORT=8642

# ---------------------------------------------------------------------------
# Expose the gateway port for documentation purposes.
# Render reads the PORT env var, not EXPOSE, but this is useful locally.
# ---------------------------------------------------------------------------
EXPOSE 8642

# ---------------------------------------------------------------------------
# Override the base image entrypoint with our wrapper script.
# The wrapper will eventually exec into `hermes gateway run`.
# ---------------------------------------------------------------------------
ENTRYPOINT ["/entrypoint.sh"]
