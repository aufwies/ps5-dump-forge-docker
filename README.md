# ps5-dump-forge-docker

[ps5-dump-forge](https://github.com/quer3q/ps5-dump-forge) 的 Docker 化部署，为 **Synology NAS (arm64)** 准备——浏览器直接操作 PS5 游戏 dump 的转换 / 编辑 / 打包（folder ⇄ exfat ⇄ ffpkg ⇄ ffpfs ⇄ FPKG，zip/7z/rar 直读，zstd/LZ4 asset pack）。

## 为什么有这个项目

官方 release 的 Linux CLI **没有内嵌 Web 前端**（直接跑 `serve` 会提示 `web UI not built`）。本项目从源码多阶段构建：`npm run build:http` 生成前端 → 嵌入 Rust 二进制 → 装进运行时镜像，得到一个开箱即用的 WebUI 服务。

## 镜像

```
git.app.REDACTED.DOMAIN/rgan/ps5-dump-forge:arm64    # Synology arm64 NAS 用这个
git.app.REDACTED.DOMAIN/rgan/ps5-dump-forge:latest   # 同 digest 别名
```

镜像**不钉死任何运行用户**（无 USER 指令）——身份由 compose 的 `user:` 注入。

## 部署（Synology Container Manager）

1. **确认游戏目录属主的 UID/GID**：SSH 到 NAS 跑 `ls -ln /volume1/你的游戏目录`（第 3/4 列就是 uid/gid）
2. 把本仓库放到 NAS（如 `/volume1/docker/ps5-dump-forge-docker/`）
3. 编辑 `docker-compose.yaml`：
   - ⚠️ **必改 `user: "<UID>:<GID>"`**（第 1 步查到的）——漏了就是 `Permission denied (os error 13)`
   - 按需改 `volumes` 里的游戏目录路径（**避免带空格的路径**）
4. Container Manager → 项目 → 新建 → 选该目录 → 起项目
   - 改过 compose 后要**删项目重新导入**（"更新"按钮不重读文件，群晖老坑）
5. 镜像拉取认证：Container Manager → 镜像 → 添加 `git.app.REDACTED.DOMAIN` 的账户
6. 浏览器开 `http://<NAS-IP>:8095`

## ⚠️ 安全边界（务必遵守）

`serve` 模式**无任何鉴权**（官方设计如此）：不做 pairing、不校验 Host/Origin——**任何能访问 NAS 8095 端口的人都能读写挂载目录**。因此：

- 只做内网端口映射（如本 compose）
- **不要**挂公网域名 / 反代到 ESA / 暴露到 VPN 外
- 不需要时停掉项目

## 多目录

`serve` 支持多个根目录——compose 里每加一个挂载就加一个 `--root`：

```yaml
    volumes:
      - /volume1/ps5games:/games:rw
      - /volume1/ps5dlc:/dlc:rw
    command: ["--root", "/games", "--root", "/dlc"]
```

## 升级 ps5-dump-forge 版本

源码默认取 upstream main。要锁版本：把构建用的源码 tarball 换成对应 tag 重新 build（见 AGENT.md 构建节）。
