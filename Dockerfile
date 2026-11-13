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

# ── Stage 2b: 交叉编译 x86_64 (arm64 宿主; C 依赖需 cross-CC) ──
FROM ${BASE_PREFIX}rust:1-bookworm AS build-x86
ARG MIRROR
WORKDIR /src
COPY src/ ./
RUN rm -f rust-toolchain.toml
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++
# rustup dist 走华为云镜像 (rsproxy 缺 x86_64 std 组件 404; 官方 CDN GET 龟速)
ARG RUSTUP_MIRROR=https://mirrors.huaweicloud.com/rustup
ENV RUSTUP_DIST_SERVER=${RUSTUP_MIRROR}/ \
    RUSTUP_UPDATE_ROOT=${RUSTUP_MIRROR}/rustup/
RUN if [ "$MIRROR" = "on" ]; then \
      printf '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n[net]\ngit-fetch-with-cli = true\n' > /usr/local/cargo/config.toml; \
    fi \
    && if [ "$MIRROR" = "on" ]; then sed -i "s|deb.debian.org|mirror.nju.edu.cn|g" /etc/apt/sources.list.d/debian.sources; fi \
    && apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc-x86-64-linux-gnu g++-x86-64-linux-gnu \
    && rustup target add x86_64-unknown-linux-gnu
RUN cd app && rm -rf dist-http; true
COPY --from=web /src/app/dist-http /src/app/dist-http
RUN cargo build --release --target x86_64-unknown-linux-gnu -p ps5-dump-forge-cli \
    && cp target/x86_64-unknown-linux-gnu/release/ps5-dump-forge /usr/local/bin/

# ── Stage 2c: 交叉编译 aarch64 (x86 宿主, GitHub runner 用; 与 2b 对称) ──
FROM ${BASE_PREFIX}rust:1-bookworm AS build-arm64
ARG MIRROR
WORKDIR /src
COPY src/ ./
RUN rm -f rust-toolchain.toml
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
ARG RUSTUP_MIRROR=https://mirrors.huaweicloud.com/rustup
ENV RUSTUP_DIST_SERVER=${RUSTUP_MIRROR}/ \
    RUSTUP_UPDATE_ROOT=${RUSTUP_MIRROR}/rustup/
RUN if [ "$MIRROR" = "on" ]; then \
      printf '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n[net]\ngit-fetch-with-cli = true\n' > /usr/local/cargo/config.toml; \
    fi \
    && if [ "$MIRROR" = "on" ]; then sed -i "s|deb.debian.org|mirror.nju.edu.cn|g" /etc/apt/sources.list.d/debian.sources; fi \
    && apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    && rustup target add aarch64-unknown-linux-gnu
RUN cd app && rm -rf dist-http; true
COPY --from=web /src/app/dist-http /src/app/dist-http
RUN cargo build --release --target aarch64-unknown-linux-gnu -p ps5-dump-forge-cli \
    && cp target/aarch64-unknown-linux-gnu/release/ps5-dump-forge /usr/local/bin/

# ── Stage 3: 运行时三变体 (无 USER; 身份由 compose user: 注入) ──
# CI 用 --target 剪枝: rt-native=宿主原生; rt-x86/rt-arm64=交叉产物
FROM ${BASE_PREFIX}debian:trixie AS runtime-base
ARG MIRROR
RUN if [ "$MIRROR" = "on" ]; then sed -i "s|deb.debian.org|mirror.nju.edu.cn|g" /etc/apt/sources.list.d/debian.sources; fi \
    && apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /games
EXPOSE 8095
ENTRYPOINT ["/usr/local/bin/ps5-dump-forge", "serve", "--port", "8095"]

FROM runtime-base AS rt-native
COPY --from=build /usr/local/bin/ps5-dump-forge /usr/local/bin/ps5-dump-forge

FROM runtime-base AS rt-x86
COPY --from=build-x86 /usr/local/bin/ps5-dump-forge /usr/local/bin/ps5-dump-forge

FROM runtime-base AS rt-arm64
COPY --from=build-arm64 /usr/local/bin/ps5-dump-forge /usr/local/bin/ps5-dump-forge
