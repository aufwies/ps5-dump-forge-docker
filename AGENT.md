# AGENT.md — 工程笔记（用户文档在 README.md）

## 项目事实（2026-11-12 交付）

- 上游：quer3q/ps5-dump-forge（Rust workspace + Tauri 前端，GPL-3.0，默认分支 **main** 不是 master）
- 关键机制：`crates/ps5-dump-forge-server` 的 build.rs 把 `npm run build:http` 产物（`app/dist-http/`，可用 `FORGE_WEB_DIST` 指路）嵌入二进制为静态资源；**无产物则嵌占位页**（运行时报 `web UI not built`）——官方 release CLI 即此状态，必须源码构建。
- serve 用法：`ps5-dump-forge serve [--port N] --root <dir>...`（默认 8095；HTTP/1.1 + polling，无鉴权）。
- 现役镜像：`git.app.REDACTED.DOMAIN/rgan/ps5-dump-forge:arm64`（+latest 别名），WebUI 版 digest `855ec963`。镜像无 USER——运行身份只来自 compose `user:`。

## 构建链（全国内镜像，勿直连）

构建场所：titan（arm64 原生 docker）。

| 层 | 通道 |
|---|---|
| node:20 / rust:1 / debian:trixie 基座 | Zot（`reg.svc.REDACTED.DOMAIN` 前缀写进 FROM） |
| npm 依赖 | `registry.npmmirror.com`（Dockerfile 内 npm config） |
| crates.io | rsproxy.cn sparse index（`/usr/local/cargo/config.toml`） |
| apt | 南大 `mirror.nju.edu.cn`（sed 换 sources；**deb.debian.org 直连会被掐死，apt 层卡 10 分钟+就是它**） |

源码获取：`https://api.github.com/repos/quer3q/ps5-dump-forge/tarball/main`（api.github 直连可达但慢，断点续传 `curl -C -`；`raw.githubusercontent` 与 `releases/download` 均不可靠）。锁定版本则换 `/tarball/vX.Y.Z`。源码放 build ctx 的 `src/`（Dockerfile COPY src/）。

### Rust 层坑
- `rust-toolchain.toml` 钉 stable channel + darwin targets → 容器内会触发 rustup 在线拉取（rsproxy rust-static 的 channel manifest 也会 `no release found for 'stable'`）。**解法：构建时 `rm -f rust-toolchain.toml`，用 rust:1 出厂工具链（零下载）**。
- workspace `[patch.crates-io] lzma-rust2 = path vendor/`——vendor 目录随源码走，勿删。

### 验收判据
容器起来后 `curl /` 返回 `<!doctype html>` + `forge.appcache`（真 UI）；`curl /api/jobs` 返回 `{"instance":...,"jobs":[]}`。若返回 "web UI not built" = dist-http 没嵌进去（查 Stage 1 产物 COPY）。

## 部署坑（NAS 侧）

- **compose `user: "<UID>:<GID>"` 必填**（= 挂载目录属主，`ls -ln` 查）。镜像 root/uid1000 与 Synology 目录属主对不上 → `os error 13`。写入产物属主 = 该 uid，File Station/SMB 后续操作才不卡。
- 路径带空格（`PS5 Games`）必须整体引号包裹；能不用空格路径就不用。
- Container Manager "更新"不重读 compose——**删项目重新导入**。
- serve 无鉴权：仅内网端口映射，禁上公网域名/ESA。

## registry 操作坑（forgejo v15）

- **建仓 API 是老的 `POST /api/v1/user/repos`（201）；`POST /api/v1/repos` 返回 404 page not found**（新端点在此实例没有路由）。push-to-create 关闭。
- 大 blob（>600MB）上传/下载：443 经 NAS traefik 曾经双雷（readTimeout 60s 已修 0s；**h2 响应流挂死未修**——containerd/大 pull 挂死零流量就是它，绕法=节点 registries.yaml mirror 到 `http://192.0.2.1:13000` 直连）。小镜像（<500MB）443 无碍。
- **按 digest DELETE manifest 会连带消灭同 digest 的所有别名 tag**——整理 tag 别删共享 digest。
- 私有镜像节点拉取凭据随 GIT_APP_TOKEN 轮换失效：k3s 侧重建 `git-app-regcred`，Container Manager 侧重存密码。

## 本仓维护

- compose 是 NAS 部署模板：**不含任何凭据**（registry 认证在 Container Manager 镜像账户里，不进仓）。
- 改 Dockerfile 后重建：titan 上 `docker build -t git.app.REDACTED.DOMAIN/rgan/ps5-dump-forge:arm64 -t ...:latest .` → 推双 tag → NAS 删项目重导。
