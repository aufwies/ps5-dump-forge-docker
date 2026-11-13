# ps5-dump-forge WebUI — 多阶段构建 (npm 前端 → Rust 后端 → 运行时)
#
# MIRROR 开关 (build-arg, 默认 on):
#   on  = 全国内镜像 (Zot 基座 / npmmirror / rsproxy.cn / 南大 apt) — 内网/国内 runner
#   off = 官方源 (docker.io / npmjs / crates.io / deb.debian.org) — GitHub 等海外 runner
# 运行身份不在镜像钉死 — 由部署侧 compose user: 注入

ARG MIRROR=on
ARG BASE_PREFIX=reg.svc.REDACTED.DOMAIN/docker.io/library/

# ── Stage 1: 前端 (npm run build:http → dist-http) ──
FROM ${BASE_PREFIX}node:20-bookworm AS web
ARG MIRROR
WORKDIR /src/app
COPY src/app/package.json src/app/package-lock.json ./
RUN if [ "$MIRROR" = "on" ]; then npm config set registry https://registry.npmmirror.com; fi \
    && npm ci --no-audit --no-fund
COPY src/app/ ./
RUN npm run build:http

# ── Stage 2: Rust 后端 ──
FROM ${BASE_PREFIX}rust:1-bookworm AS build
ARG MIRROR
WORKDIR /src
COPY src/ ./
# rust-toolchain.toml 钉 darwin targets + stable channel 会触发 rustup 在线拉取;
# 用 rust:1 出厂工具链 (零下载)
RUN rm -f rust-toolchain.toml
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
RUN if [ "$MIRROR" = "on" ]; then \
      printf '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n[net]\ngit-fetch-with-cli = true\n' > /usr/local/cargo/config.toml; \
    fi
RUN cd app && rm -rf dist-http; true
COPY --from=web /src/app/dist-http /src/app/dist-http
RUN cargo build --release -p ps5-dump-forge-cli \
    && cp target/release/ps5-dump-forge /usr/local/bin/

# ── Stage 3: 运行时 (无 USER; 身份由 compose user: 注入) ──
FROM ${BASE_PREFIX}debian:trixie
ARG MIRROR
RUN if [ "$MIRROR" = "on" ]; then sed -i "s|deb.debian.org|mirror.nju.edu.cn|g" /etc/apt/sources.list.d/debian.sources; fi \
    && apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/ps5-dump-forge /usr/local/bin/ps5-dump-forge
WORKDIR /games
EXPOSE 8095
ENTRYPOINT ["/usr/local/bin/ps5-dump-forge", "serve", "--port", "8095"]
