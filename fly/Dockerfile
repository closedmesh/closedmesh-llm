# mesh-llm Fly.io console image
#
# Deploy:
#   fly deploy --config fly/console/fly.toml --dockerfile fly/Dockerfile
#   Set MESH_HEADLESS=1 in fly.toml [env] to run API-only (no web UI)

# syntax=docker/dockerfile:1.7

FROM node:24-alpine AS ui-builder
WORKDIR /app
COPY mesh-llm/ui/package.json mesh-llm/ui/package-lock.json ./
# No `--mount=type=cache` here — Railway's BuildKit fork requires a
# provider-specific cache-key prefix. Re-downloading npm deps adds a few
# seconds per build and keeps the Dockerfile portable across Fly,
# Railway, plain Docker, and CI.
RUN npm ci
COPY mesh-llm/ui/ ./
RUN npm run build

FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git cmake ninja-build pkg-config libssl-dev libdbus-1-dev python3 build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:$PATH"
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY mesh-llm/Cargo.toml mesh-llm/Cargo.toml
COPY mesh-llm/build.rs mesh-llm/build.rs
COPY mesh-llm/plugin/Cargo.toml mesh-llm/plugin/Cargo.toml
COPY mesh-llm/plugin/build.rs mesh-llm/plugin/build.rs
COPY mesh-llm/proto/ mesh-llm/proto/
COPY mesh-llm/ mesh-llm/
COPY mesh-client/ mesh-client/
COPY mesh-api/ mesh-api/
COPY mesh-host-core/ mesh-host-core/
COPY mesh-api-ffi/ mesh-api-ffi/
COPY mesh-llm-test-harness/ mesh-llm-test-harness/
COPY tools/xtask/ tools/xtask/
COPY --from=ui-builder /app/dist mesh-llm/ui/dist
# Same portability note as the npm RUN above: no cache mounts. The cargo
# build is the long pole anyway (10–15 min cold) and Railway/Fly cold
# starts already pay this cost on most deploys.
RUN cargo build --release --locked -p mesh-llm && \
    cp target/release/closedmesh /usr/local/bin/closedmesh

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libgomp1 libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/closedmesh /usr/local/bin/closedmesh
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV APP_MODE=console
EXPOSE 3131 9337
ENTRYPOINT ["/entrypoint.sh"]
