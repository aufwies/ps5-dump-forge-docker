# ps5-dump-forge-docker

[ps5-dump-forge](https://github.com/quer3q/ps5-dump-forge) 的 Docker 化部署，为 **Synology NAS (arm64)** 准备——浏览器直接操作 PS5 游戏 dump 的转换 / 编辑 / 打包（folder ⇄ exfat ⇄ ffpkg ⇄ ffpfs ⇄ FPKG，zip/7z/rar 直读，zstd/LZ4 asset pack）。

## 为什么有这个项目

官方 release 的 Linux CLI **没有内嵌 Web 前端**（直接跑 `serve` 会提示 `web UI not built`）。本项目从源码多阶段构建：`npm run build:http` 生成前端 → 嵌入 Rust 二进制 → 装进运行时镜像，得到一个开箱即用的 WebUI 服务。支持双架构（arm64 原生 + x86 Rust 交叉编译，单 runner 双产出）。

## 镜像

```
ghcr.io/<OWNER>/ps5-dump-forge:arm64    # Synology arm64 NAS
ghcr.io/<OWNER>/ps5-dump-forge:x86      # x86_64 设备
```

（私有 registry 用户把地址换成自己的即可。）

镜像**不钉死任何运行用户**（无 USER 指令）——身份由 compose 的 `user:` 注入。

## 部署（Synology Container Manager）

1. **确认游戏目录属主的 UID/GID**：SSH 到 NAS 跑 `ls -ln /volume1/你的游戏目录`（第 3/4 列就是 uid/gid）
2. 把本仓库放到 NAS（如 `/volume1/docker/ps5-dump-forge-docker/`）
3. 编辑 `docker-compose.yaml`：
   - ⚠️ **必改 `user: "<UID>:<GID>"`**（第 1 步查到的）——漏了就是 `Permission denied (os error 13)`
   - 按需改 `volumes` 里的游戏目录路径（**避免带空格的路径**）
4. Container Manager → 项目 → 新建 → 选该目录 → 起项目
   - 改过 compose 后要**删项目重新导入**（"更新"按钮不重读文件，群晖老坑）
5. 镜像拉取认证（私有 registry 时）：Container Manager → 镜像 → 添加 registry 的账户
6. 浏览器开 `http://<NAS-IP>:8095`

## ⚠️ 安全边界（务必遵守）

`serve` 模式**无任何鉴权**（官方设计如此）：不做 pairing、不校验 Host/Origin——**任何能访问 NAS 8095 端口的人都能读写挂载目录**。因此：

- 只做内网端口映射（如本 compose）
- **不要**挂公网域名 / 反代公网 / 暴露到不受信网络
- 不需要时停掉项目

## 多目录

`serve` 支持多个根目录——compose 里每加一个挂载就加一个 `--root`：

```yaml
    volumes:
      - /volume1/ps5games:/games:rw
      - /volume1/ps5dlc:/dlc:rw
    command: ["--root", "/games", "--root", "/dlc"]
```

## CI/CD（GitHub Actions 与 Forgejo Actions 双平台）

每日定时检查上游 main 的新提交，有更新就重新构建并推送双架构镜像（构建后把上游 sha 记录回 `.upstream-sha`）。也可手动触发，参数：

- `mirror`：`on`=国内镜像源（默认，Forgejo 内网 runner 用，通道矩阵见 AGENT.md）；`off`=官方源（GitHub runner 默认自动 off）
- `force`：`true` 跳过 sha 检查强制构建

镜像 tag 规则：`arm64` / `x86`（本机原生 + Rust 交叉编译另一架构）+ `latest-<arch>` 别名。

Secrets / Variables：

| 平台 | 配置项 | 说明 |
|---|---|---|
| GitHub | 无需手配 | 内置 `GITHUB_TOKEN` 推 ghcr.io |
| Forgejo | secret `REGISTRY_PASSWORD`（clone+推镜像）；variable `INTERNAL_REGISTRY_IMAGE`（私有 registry 镜像全名） | 内网双架构发布 |
