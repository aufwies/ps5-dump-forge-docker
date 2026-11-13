# ps5-dump-forge-docker

[ps5-dump-forge](https://github.com/quer3q/ps5-dump-forge) 的 Docker 化部署，为 **Synology NAS (arm64)** 准备——浏览器直接操作 PS5 游戏 dump 的转换 / 编辑 / 打包（folder ⇄ exfat ⇄ ffpkg ⇄ ffpfs ⇄ FPKG，zip/7z/rar 直读，zstd/LZ4 asset pack）。

## 为什么有这个项目

官方 release 的 Linux CLI **没有内嵌 Web 前端**（跑 `serve` 会报 `web UI not built`）。本项目从源码多阶段构建：前端生成 → 嵌入 Rust 二进制 → 装进运行时镜像，开箱即用的 WebUI 服务。双架构产出（arm64 + x86 交叉编译）。

## 镜像

```
ghcr.io/<OWNER>/ps5-dump-forge:arm64    # Synology arm64 NAS
ghcr.io/<OWNER>/ps5-dump-forge:x86      # x86_64 设备
```

私有 registry 用户把地址换成自己的即可。镜像不钉死运行用户——身份由 compose 的 `user:` 注入。

## 部署（Synology Container Manager）

1. **查游戏目录属主的 UID/GID**：SSH 到 NAS 跑 `ls -ln /volume1/你的游戏目录`
2. 仓库放到 NAS（如 `/volume1/docker/ps5-dump-forge-docker/`）
3. 编辑 `docker-compose.yaml`：
   - ⚠️ **必改 `user: "<UID>:<GID>"`**——漏了就是 `Permission denied (os error 13)`
   - 改 `volumes` 游戏目录路径（避免带空格的路径）
   - `image` 按需换成你的 registry 地址
4. Container Manager → 项目 → 新建 → 选该目录 → 起项目（改过 compose 后**删项目重新导入**，"更新"按钮不重读文件）
5. 私有 registry 需在 Container Manager 镜像里添加认证
6. 浏览器开 `http://<NAS-IP>:8095`

## ⚠️ 安全边界

`serve` 模式**无任何鉴权**（官方设计）：能访问 8095 端口的人就能读写挂载目录。只做内网端口映射，不要挂公网域名，不用时停掉项目。

## 多目录

```yaml
    volumes:
      - /volume1/ps5games:/games:rw
      - /volume1/ps5dlc:/dlc:rw
    command: ["--root", "/games", "--root", "/dlc"]
```

## CI/CD

GitHub Actions 与 Forgejo Actions 双平台自动构建：每日检查上游更新，有新提交自动重建双架构镜像并推送。环境由各平台仓库的 variables 自描述（配置矩阵见 AGENT.md）；手动强制构建在 Actions 页触发（`force` 参数）。
