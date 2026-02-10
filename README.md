# 内网静态文档部署方案（Docker Nginx）

目标：
- 文档部署到内网独立服务器，电脑关机后仍可访问
- 不依赖 GitLab/Jenkins
- 不依赖 git/svn
- 保持访问路径不变：
  - `http://<server-ip>:9776/RCOS_API_DOC.html`
  - `http://<server-ip>:9776/5gos_liuyd.html`

涉及文件：
- `RCOS_API_DOC.html`
- `RCOS_API_DOC.assets/`
- `5gos_liuyd.html`
- `5gos_liuyd.assets/`

## 1. 服务器初始化（只做一次）

要求：
- 服务器已安装 Docker
- 有 `docker compose` 插件（或 `docker-compose`）

把目录传到服务器：

```bash
scp -r intranet-doc-deploy root@<server-ip>:/tmp/
```

执行初始化：

```bash
ssh root@<server-ip>
cd /tmp/intranet-doc-deploy/server
chmod +x *.sh
./init_server.sh
```

初始化会：
- 创建 `/srv/intra-docs/releases`
- 安装 `/usr/local/bin/deploy-intra-docs.sh`
- 写入 `/opt/intra-docs/nginx/intra-docs.conf`
- 写入 `/opt/intra-docs/docker-compose.yml`
- 启动容器 `intra-docs-nginx`（端口映射 `9776:80`）

## 2. 本地一键发布（每次更新后执行）

在 Windows 本机执行：

```powershell
powershell -ExecutionPolicy Bypass -File D:\liuyongdan\工作\intranet-doc-deploy\windows\publish.ps1 -ServerHost <server-ip> -ServerUser root -ServerPort 22 -SourceDir D:\liuyongdan\工作
```

发布脚本会：
1. 打包 2 个 html + 2 个 assets 目录
2. 上传到服务器 `/tmp`
3. 调用 `/usr/local/bin/deploy-intra-docs.sh`
4. 原子切换 `current` 软链
5. 让 Docker Nginx reload

说明：
- 目前默认打包格式为 `tar.gz`（优先解决 Windows 到 Linux 的中文文件名乱码问题）
- 服务端解包脚本同时兼容历史 `zip` 包
- 服务端默认仅保留最近 20 个发布版本（可通过环境变量 `KEEP_RELEASES` 调整）

## 3. 回滚

服务器执行：

```bash
ls -1 /srv/intra-docs/releases
ln -sfn /srv/intra-docs/releases/<old_release_dir> /srv/intra-docs/current
docker exec intra-docs-nginx nginx -s reload
```

## 4. 故障排查

1. 页面 404：
- 检查 `/srv/intra-docs/current/RCOS_API_DOC.html`
- 检查容器：`docker ps | grep intra-docs-nginx`

2. 图片不显示：
- 检查 `RCOS_API_DOC.assets`、`5gos_liuyd.assets` 是否在 `current` 内

3. 发布时报 compose 不存在：
- 安装 `docker compose` 插件，或安装 `docker-compose`

## 5. 可选：先从 Markdown 生成 HTML

在本机执行：

```powershell
cd D:\liuyongdan\工作
.\deploy_docs_716.ps1 -BuildHtml -NoPause
```

说明：
- 生成脚本：`intranet-doc-deploy/tools/build_html_with_pandoc_template.py`
- 使用 `pandoc` + 模板 `intranet-doc-deploy/tools/templates/pandoc_github_docs.html` 生成 HTML
- 包含目录折叠、过滤、暗色模式、返回顶部、代码复制与 HTTP 片段优化渲染
- 然后走发布流程上传到服务器
