# AGENT.md — 工程笔记（用户文档在 README.md）

## 上游事实

- 上游：quer3q/ps5-dump-forge（Rust workspace + Tauri 前端，GPL-3.0，默认分支 **main** 不是 master）
- 关键机制：`crates/ps5-dump-forge-server` 的 build.rs 把 `npm run build:http` 产物（`app/dist-http/`，可用 `FORGE_WEB_DIST` 指路）嵌入二进制为静态资源；**无产物则嵌占位页**（运行时报 `web UI not built`）——官方 release CLI 即此状态，必须源码构建。
- serve 用法：`ps5-dump-forge serve [--port N] --root <dir>...`（默认 8095；HTTP/1.1 + polling，无鉴权）。
- 镜像不钉 USER——运行身份只来自 compose `user:`。

## 构建链（mirror=on 时的国内镜像矩阵）

| 层 | 通道 |
|---|---|
| node/rust/debian 基座 | 私有 mirror registry 前缀（CI 传入 `BASE_PREFIX`；mirror=off 时为 docker.io） |
| npm 依赖 | `registry.npmmirror.com` |
| crates.io | rsproxy.cn sparse index（`/usr/local/cargo/config.toml`） |
| **rustup dist（交叉 std 组件）** | **华为云 `mirrors.huaweicloud.com/rustup/`**——rsproxy 缺 x86_64 std 组件（404 实测）、官方 CDN GET 龟速、SJTU 连不上、USTC 403；腾讯云/TUNA 可作备选 |
| apt | 南大 `mirror.nju.edu.cn`（**deb.debian.org 直连会被掐死，apt 层卡 10 分钟+就是它**） |

源码获取：`https://api.github.com/repos/quer3q/ps5-dump-forge/tarball/main`（api.github 直连可达但慢，断点续传 `curl -C -`；`raw.githubusercontent` 与 `releases/download` 均不可靠）。锁定版本则换 `/tarball/vX.Y.Z`。

### Rust 层坑
- `rust-toolchain.toml` 钉 stable channel + darwin targets → 容器内触发 rustup 在线拉取并失败（`no release found for 'stable'`，镜像源 channel manifest 缺）。**解法：构建时 `rm -f rust-toolchain.toml`，用 rust:1 出厂工具链（零下载）**。
- workspace `[patch.crates-io] lzma-rust2 = path vendor/`——vendor 目录随源码走，勿删。
- **交叉编译（方案 B）**：C 依赖（zstd-sys / lz4-sys / ring）需要 cross-CC：`gcc-x86-64-linux-gnu`（或对称的 aarch64 版）+ `CC_<target>`/`CARGO_TARGET_*_LINKER` 环境变量。Dockerfile 三 build stage（native / build-x86 / build-arm64）+ 三 runtime 变体（rt-native / rt-x86 / rt-arm64），**CI 用 `--target` 剪枝，每次恰好两轮编译**。交叉产物无法在构建机运行——冒烟只测原生架构，交叉架构以编译成功为准（发布后由异构 runner/用户首拉兜底）。
- **github.com 主域的 git 协议（clone/ls-remote）在部分容器网络内会被掐**（传输中途 RST）——CI 里一切 github 访问走 api.github.com HTTP 通道。

### 验收判据
容器起来后 `curl /` 返回 `<!doctype html>` + `forge.appcache`（真 UI）；`curl /api/jobs` 返回 `{"instance":...,"jobs":[]}`。若返回 "web UI not built" = dist-http 没嵌进去（查 Stage 1 产物 COPY）。

## 部署坑（NAS 侧）

- **compose `user: "<UID>:<GID>"` 必填**（= 挂载目录属主，`ls -ln` 查）。镜像 root/uid1000 与 Synology 目录属主对不上 → `os error 13`。写入产物属主 = 该 uid，File Station/SMB 后续操作才不卡。
- 路径带空格（如 `PS5 Games`）必须整体引号包裹；能不用空格路径就不用。
- Container Manager "更新"不重读 compose——**删项目重新导入**。
- serve 无鉴权：仅内网端口映射，禁上公网域名。

## Forgejo Actions 要点

- 建仓 API 用老的 `POST /api/v1/user/repos`（201）；`POST /api/v1/repos` 在部分版本 404。push-to-create 常关闭。
- **按 digest DELETE manifest 会连带消灭同 digest 的所有别名 tag**——整理 tag 别删共享 digest。
- 私有 registry 拉取凭据随 token 轮换失效，k3s 侧重建 regcred / Container Manager 侧重存密码。
- workflow 表达式尽量收进 shell 判断（复杂 `${{ }}` 插值失败 = job 直接 fail）。
- 内网 registry 镜像名用 repo variable `INTERNAL_REGISTRY_IMAGE` 注入（公开文件不写死私有地址）。

## CI 配置矩阵（jellyfin-cix 式环境自描述）

workflow 顶层 env 全部 vars 注入（配了就用，软互斥是约定非校验）：

| Variable | Forgejo (git.app) | GitHub |
|---|---|---|
| `USE_MIRROR` | `true`（Dockerfile 国内源人格） | 不配（false 兜底，官方源） |
| `HTTPS_PROXY` | `http://<内网代理>`（github 访问） | 不配（直连） |
| `REGISTRY_IMAGE` | `<内网registry>/rgan/ps5-dump-forge` | 不配（ghcr.io/<owner> 兜底） |
| `BASE_MIRROR_PREFIX` | `<mirror>/docker.io/library/` | 不配（docker.io 兜底） |
| `REGISTRY_USER` | 内网 registry 用户 | 不配 |

- variables API：**POST 创建 / PUT 更新已存在**（对不存在的变量 PUT=404）；GET 列表随时可读。
- secrets：`REGISTRY_PASSWORD`（内网 clone+推镜像 token）。
- 内网 job 容器网络 api.github 直连不通——HTTPS_PROXY 必配，否则 check 自动跳过当轮。
- 顶层 env 的 HTTPS_PROXY 会作用于步骤内 git/curl/docker CLI：git 内网 clone 用 `-c http.proxy=` 覆盖、本地 curl 冒烟用 `--noproxy "*"`。
- **docker 容器名最短 2 字符**（`--name t` 报 Invalid container name）——smoke 容器名用多字符。
- dispatch inputs 只留 `force`；mirror 不是人工开关（环境自描述）。

## 本仓维护

- compose 是 NAS 部署模板：**不含任何凭据与私有地址**。
- 改 Dockerfile 后重建：CI force 触发即可（双架构全链含冒烟）。
