# TDLib bridge worker.
#
# Two stages: the first builds libtdjson from the pinned tag so the runtime image
# carries no toolchain, the second runs Node against the prebuilt shared library.
# The TDLib version is pinned deliberately — TDLib changes its JSON API between
# minor releases, and a bridge that silently upgrades can start failing every send
# (see docs/runbook.md §6).

FROM debian:bookworm-slim AS tdlib
ARG TDLIB_VERSION=v1.8.43
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates libssl-dev zlib1g-dev \
 && git clone --depth 1 --branch "${TDLIB_VERSION}" https://github.com/tdlib/td.git /tmp/td \
 && cmake -S /tmp/td -B /tmp/build -DCMAKE_BUILD_TYPE=Release -TDJSON_JSON_READONLY=OFF \
 && cmake --build /tmp/build --target tdjson -j "$(nproc)" \
 && cmake --install /tmp/build --component lib --component headers \
 && rm -rf /var/lib/apt/lists

FROM node:22-bookworm-slim AS runtime
# `tini` reaps the TDLib worker threads and forwards SIGTERM, which is what makes
# the graceful shutdown path (flush outbox lease, close sessions) actually run.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini libssl3 zlib1g \
 && rm -rf /var/lib/apt/lists

WORKDIR /app
COPY package.json package-lock.json* ./
# Dev dependencies stay out of the image: the test-suite runs in CI from a checkout,
# not inside a deployed container.
RUN npm ci --omit=dev --no-audit --no-fund

COPY --from=tdlib /usr/local/lib/libtdjson.so* /usr/local/lib/
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && rm -rf /app/.npm-cache

ENV NODE_ENV=production \
    BRIDGE_TRANSPORT=koffi \
    TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so \
    BRIDGE_HEALTH_HOST=0.0.0.0 \
    BRIDGE_HEALTH_PORT=8787 \
    BRIDGE_DATA_DIR=/var/lib/messengerx-bridge

RUN mkdir -p /var/lib/messengerx-bridge && chown -R node:node /var/lib/messengerx-bridge /app
USER node
VOLUME ["/var/lib/messengerx-bridge"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=4s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.BRIDGE_HEALTH_PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "dist/main.js"]
