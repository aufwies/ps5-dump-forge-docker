# ps5-dump-forge WebUI 完整构建 — 多阶段 (npm 前端 → rust 后端 → 运行时)
# 全程国内镜像: Zot(基座) + npmmirror(npm) + rsproxy.cn(crates.io)
# 背景: 官方 release CLI 未嵌 http 前端 (build.rs 需 app/dist-http), 故从源码构建

# ── Stage 1: 前端 (npm run build:http → dist-http) ──
FROM reg.svc.REDACTED.DOMAIN/docker.io/library/node:20-bookworm AS web
WORKDIR /src/app
COPY src/app/package.json src/app/package-lock.json ./
RUN npm config set registry https://registry.npmmirror.com \
    && npm ci --no-audit --no-fund
COPY src/app/ ./
RUN npm run build:http

# ── Stage 2: Rust 后端 (vendor 补丁 + rsproxy 镜像源) ──
FROM reg.svc.REDACTED.DOMAIN/docker.io/library/rust:1-bookworm AS build
WORKDIR /src
COPY src/ ./
# rust-toolchain.toml 钉了 darwin targets + stable channel 触发在线拉取;
# rust:1 出厂自带工具链, 删掉 toml 直接用 (零下载)
RUN rm -f rust-toolchain.toml
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
RUN mkdir -p /usr/local/cargo \
    && cat > /usr/local/cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = 'rsproxy-sparse'
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
RUN cd app && rm -rf dist-http; true
COPY --from=web /src/app/dist-http /src/app/dist-http
RUN cargo build --release -p ps5-dump-forge-cli \
    && cp target/release/ps5-dump-forge /usr/local/bin/

# ── Stage 3: 运行时 (无 USER; 运行身份由部署侧 compose user: 注入, 对接挂载目录属主) ──
FROM reg.svc.REDACTED.DOMAIN/docker.io/library/debian:trixie
RUN sed -i "s|deb.debian.org|mirror.nju.edu.cn|g" /etc/apt/sources.list.d/debian.sources \
    && apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/ps5-dump-forge /usr/local/bin/ps5-dump-forge
WORKDIR /games
EXPOSE 8095
ENTRYPOINT ["/usr/local/bin/ps5-dump-forge", "serve", "--port", "8095"]
