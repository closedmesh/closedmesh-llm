#!/bin/sh
# mesh-llm docker entrypoint — selects runtime mode via APP_MODE env var
# The UI is always embedded in the binary via include_dir!; there is no separate
# UI-less build.
#
# Modes (set via APP_MODE env var or ARG CMD in Dockerfile):
#   console  — client node: API on port 9337 + web console on port 3131 (default)
#   worker   — full mesh-llm node with bundled llama binaries (full-node images only)
#   (default) — pass through all args directly to mesh-llm
#
# Optional modifier:
#   MESH_HEADLESS=1  — append --headless to console/worker modes; keeps /api/* alive
#                      and returns 404 for web UI routes (/, /dashboard, /chat/*, assets)
#                      Ignored in pass-through mode (set the flag yourself instead).
#
# Examples:
#   docker run -e APP_MODE=console mesh-llm:client              # normal, UI enabled
#   docker run -e APP_MODE=console -e MESH_HEADLESS=1 mesh-llm:client  # API-only
#   docker run -e APP_MODE=worker  -e MESH_HEADLESS=1 mesh-llm:cpu     # worker, no UI
set -e

HEADLESS_FLAG=""
if [ "$MESH_HEADLESS" = "1" ] || [ "$MESH_HEADLESS" = "true" ]; then
  HEADLESS_FLAG="--headless"
fi

# Honor $PORT for PaaS providers (Railway, Render, Fly machine port mapping)
# that assign a port at runtime. Falls back to the OpenAI-compatible default.
API_PORT="${PORT:-9337}"
CONSOLE_PORT="${CONSOLE_PORT:-3131}"

# When $MESH_AUTH_TOKEN is set we expose the runtime *only* via a Caddy
# gateway that enforces `Authorization: Bearer <token>`. closedmesh itself
# binds to 127.0.0.1 (no `--listen-all`) and Caddy listens on $API_PORT,
# proxying to it. This is the right shape for a public PaaS deployment.
#
# Without the token (local docker, internal dev, Tailscale-only nets) we
# skip Caddy entirely and let closedmesh bind to 0.0.0.0 directly — same
# behaviour as before this change.
if [ -n "${MESH_AUTH_TOKEN:-}" ]; then
  AUTH_MODE=1
  INTERNAL_PORT=9337
  LISTEN_FLAG=""
  echo "[entrypoint] MESH_AUTH_TOKEN is set — running Caddy auth gateway in front of closedmesh."
else
  AUTH_MODE=0
  INTERNAL_PORT="$API_PORT"
  LISTEN_FLAG="--listen-all"
fi

start_caddy() {
  # Caddy reads ${GATEWAY_PORT} / ${INTERNAL_PORT} / ${MESH_AUTH_TOKEN}
  # from the environment via the Caddyfile's `{$VAR}` placeholders.
  GATEWAY_PORT="$API_PORT" INTERNAL_PORT="$INTERNAL_PORT" \
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
  CADDY_PID=$!
  trap 'kill -TERM $CADDY_PID 2>/dev/null || true' INT TERM EXIT
}

case "$APP_MODE" in
  console)
    if [ "$AUTH_MODE" = 1 ]; then start_caddy; fi
    # shellcheck disable=SC2086
    exec closedmesh --client --auto --port "$INTERNAL_PORT" --console "$CONSOLE_PORT" $LISTEN_FLAG $HEADLESS_FLAG
    ;;
  worker)
    BIN_DIR=/usr/local/lib/mesh-llm/bin
    set -- "$BIN_DIR"/rpc-server-*
    RPC_SERVER="$1"
    set -- "$BIN_DIR"/llama-server-*
    LLAMA_SERVER="$1"
    if [ ! -e "$RPC_SERVER" ] || [ ! -e "$LLAMA_SERVER" ] || [ ! -x "$BIN_DIR/llama-moe-split" ]; then
      echo "APP_MODE=worker requires bundled llama binaries in $BIN_DIR; use a full-node image (:cpu/:cuda/:rocm/:vulkan) or APP_MODE=console." >&2
      exit 1
    fi
    if [ "$AUTH_MODE" = 1 ]; then start_caddy; fi
    # shellcheck disable=SC2086
    exec closedmesh --auto --port "$INTERNAL_PORT" --console "$CONSOLE_PORT" --bin-dir "$BIN_DIR" $LISTEN_FLAG $HEADLESS_FLAG
    ;;
  *)
    exec closedmesh "$@"
    ;;
esac
