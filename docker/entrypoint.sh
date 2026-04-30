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
# Optional modifiers:
#   MESH_HEADLESS=1    — append --headless; keeps /api/* alive, returns 404 for web UI
#   MESH_AUTH_TOKEN=x  — enable Caddy bearer-token gateway (see Caddyfile / Caddyfile.open)
#
# Examples:
#   docker run -e APP_MODE=console mesh-llm:client                          # open, UI enabled
#   docker run -e APP_MODE=console -e MESH_HEADLESS=1 mesh-llm:client      # open, API-only
#   docker run -e APP_MODE=console -e MESH_AUTH_TOKEN=secret mesh-llm:client  # gated
set -e

HEADLESS_FLAG=""
if [ "$MESH_HEADLESS" = "1" ] || [ "$MESH_HEADLESS" = "true" ]; then
  HEADLESS_FLAG="--headless"
fi

# Named-mesh args. When MESH_NAME is set (default: "closedmesh") we scope
# discovery and publication to that name instead of the unnamed community
# pool. MESH_PUBLISH=1 (default in console/worker modes) tells the runtime
# to advertise this listing on Nostr so contributors running with the same
# `--mesh-name` can discover and join it. Set MESH_NAME="" to fall back to
# the unnamed community mesh, or MESH_PUBLISH=0 to keep the mesh private.
MESH_NAME="${MESH_NAME-closedmesh}"
MESH_PUBLISH="${MESH_PUBLISH-1}"
MESH_NAME_FLAG=""
PUBLISH_FLAG=""
if [ -n "$MESH_NAME" ]; then
  MESH_NAME_FLAG="--mesh-name $MESH_NAME"
fi
if [ "$MESH_PUBLISH" = "1" ] || [ "$MESH_PUBLISH" = "true" ]; then
  PUBLISH_FLAG="--publish"
fi

# Honor $PORT when the host assigns a port at runtime (e.g. Lightsail reverse
# proxy, or local docker -p overrides). Falls back to the OpenAI-compat default.
API_PORT="${PORT:-9337}"
CONSOLE_PORT="${CONSOLE_PORT:-3131}"

# Caddy always runs as the public-facing gateway on $API_PORT so that both
# the OpenAI API (/v1/*) and the admin console (/api/*) are reachable through
# a single port. closedmesh always binds to 127.0.0.1 (never --listen-all).
#
# When $MESH_AUTH_TOKEN is set we use Caddyfile (auth-gated): /v1/* and
# /api/* require Bearer, but /api/status and /v1/models are open so that
# new nodes can bootstrap and platform health checks pass without a token.
#
# Without $MESH_AUTH_TOKEN we use Caddyfile.open (transparent proxy): all
# paths are forwarded as-is. Use this only on private/internal deployments.
INTERNAL_PORT="${MESH_INTERNAL_PORT:-19337}"

if [ -n "${MESH_AUTH_TOKEN:-}" ]; then
  CADDYFILE=/etc/caddy/Caddyfile
  echo "[entrypoint] MESH_AUTH_TOKEN set — Caddy on :$API_PORT (auth) -> closedmesh on 127.0.0.1:$INTERNAL_PORT / console on 127.0.0.1:$CONSOLE_PORT"
else
  CADDYFILE=/etc/caddy/Caddyfile.open
  echo "[entrypoint] No MESH_AUTH_TOKEN — Caddy on :$API_PORT (open) -> closedmesh on 127.0.0.1:$INTERNAL_PORT / console on 127.0.0.1:$CONSOLE_PORT"
fi

start_caddy() {
  # Caddy reads {$GATEWAY_PORT}, {$SITE_ADDR}, {$INTERNAL_PORT},
  # {$CONSOLE_PORT}, and {$MESH_AUTH_TOKEN} from the environment.
  # SITE_ADDR defaults to ":$API_PORT" (plain HTTP on that port) but can
  # be set to a domain name (e.g. "mesh.closedmesh.com") so Caddy binds
  # to port 80 for that hostname — useful when the host routes 80→container.
  SITE_ADDR="${SITE_ADDR:-:$API_PORT}" \
  GATEWAY_PORT="$API_PORT" INTERNAL_PORT="$INTERNAL_PORT" CONSOLE_PORT="$CONSOLE_PORT" \
    caddy run --config "$CADDYFILE" --adapter caddyfile &
  CADDY_PID=$!
  trap 'kill -TERM $CADDY_PID 2>/dev/null || true' INT TERM EXIT
}

case "$APP_MODE" in
  console)
    start_caddy
    # shellcheck disable=SC2086
    exec closedmesh client --auto --port "$INTERNAL_PORT" --console "$CONSOLE_PORT" $HEADLESS_FLAG $MESH_NAME_FLAG $PUBLISH_FLAG
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
    start_caddy
    # shellcheck disable=SC2086
    exec closedmesh --auto --port "$INTERNAL_PORT" --console "$CONSOLE_PORT" --bin-dir "$BIN_DIR" $HEADLESS_FLAG $MESH_NAME_FLAG $PUBLISH_FLAG
    ;;
  *)
    exec closedmesh "$@"
    ;;
esac
