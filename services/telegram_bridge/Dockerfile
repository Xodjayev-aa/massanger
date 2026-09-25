# TDLib bridge worker. Build with the monorepo as the context, not this directory:
#   docker build -f services/telegram_bridge/Dockerfile -t messengerx/telegram-bridge .
# The root lockfile owns npm workspaces; there is intentionally no second lockfile
# next to this Dockerfile. Both Node and TDLib target the image's platform
# (arm64 or x86_64), so an x86-only sidecar is never silently pulled in.

FROM debian:bookworm-slim AS tdlib
# Upstream has no v1.8.43 Git tag. This is the real 1.8.43 version bump commit;
# pin the commit rather than tracking master or pretending a release tag exists.
ARG TDLIB_COMMIT=11406d9d6f3baa999b77fbd09f36c67749c31699
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates libssl-dev zlib1g-dev \
 && git init /tmp/td \
 && git -C /tmp/td remote add origin https://github.com/tdlib/td.git \
 && git -C /tmp/td fetch --depth 1 origin "${TDLIB_COMMIT}" \
 && git -C /tmp/td checkout -q --detach FETCH_HEAD \
 && cmake -S /tmp/td -B /tmp/build -DCMAKE_BUILD_TYPE=Release \
      -DTD_INSTALL_STATIC_LIBRARIES=OFF -DBUILD_TESTING=OFF \
 && cmake --build /tmp/build --target tdjson -j 2 \
 && cmake --install /tmp/build \
 && test -f /usr/local/lib/libtdjson.so \
 && rm -rf /var/lib/apt/lists/* /tmp/td /tmp/build

FROM node:22-bookworm-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
COPY services/telegram_bridge/package.json services/telegram_bridge/package.json
COPY tools/sql-test/package.json tools/sql-test/package.json
COPY tools/typecheck/package.json tools/typecheck/package.json
# TypeScript is a *dev* dependency; compile before pruning it. npm ci also uses
# the root lockfile, which works the same on arm64 and x86_64.
RUN npm ci --no-audit --no-fund
COPY services/telegram_bridge/tsconfig*.json services/telegram_bridge/
COPY services/telegram_bridge/src services/telegram_bridge/src
RUN npm run build:bridge && npm prune --omit=dev --no-audit --no-fund

FROM node:22-bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini libssl3 zlib1g \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/services/telegram_bridge/dist ./services/telegram_bridge/dist
COPY --from=builder /app/services/telegram_bridge/package.json ./services/telegram_bridge/package.json
COPY --from=tdlib /usr/local/lib/libtdjson.so* /usr/local/lib/
RUN ldconfig && mkdir -p /var/lib/messengerx-bridge \
 && chown -R node:node /var/lib/messengerx-bridge /app

ENV NODE_ENV=production \
    MESSENGERX_ENV=production \
    BRIDGE_TRANSPORT=koffi \
    TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so \
    BRIDGE_HEALTH_HOST=0.0.0.0 \
    BRIDGE_HEALTH_PORT=8787 \
    BRIDGE_DATA_DIR=/var/lib/messengerx-bridge

USER node
VOLUME ["/var/lib/messengerx-bridge"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=4s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.BRIDGE_HEALTH_PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "services/telegram_bridge/dist/main.js"]
