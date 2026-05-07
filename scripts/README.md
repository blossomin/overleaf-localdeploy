# Overleaf 社区版远端部署 + GitHub 多仓库同步

## 概述

本方案在远端 Linux 服务器上部署 Overleaf 社区版，通过 TLS NGINX 反向代理实现 HTTPS 公网访问，并通过定时脚本将**每个 Overleaf project 自动同步到独立的 GitHub 仓库**，实现数据持久化和多人协作。

## 架构

```
用户浏览器
    │ HTTPS (443)
    ▼
┌─────────┐
│  NGINX  │ ← TLS 终止
└────┬────┘
     │ HTTP
     ▼
┌───────────┐     ┌─────────┐     ┌─────────┐
│ Overleaf  │────▶│ MongoDB │     │  Redis  │
│ (CE)      │     └─────────┘     └─────────┘
└─────┬─────┘
      │ 数据目录
      ▼
┌─────────────┐    cron 定时     ┌──────────┐
│ /home/dchen/projects/overleaf│──────────────▶ │  GitHub  │
│ /data/      │  同步脚本       │  Repos   │
└─────────────┘                 └──────────┘
```

## 前置要求

- **服务器**: Ubuntu 22.04+ / Debian 12+ (推荐 4GB+ 内存)
- **网络**: 公网 IP，80/443 端口可访问
- **GitHub**: Personal Access Token (需 `repo` 权限)

## 快速开始

### 1. 上传脚本到服务器

```bash
scp -r scripts/ root@YOUR_SERVER_IP:/tmp/overleaf-deploy/
ssh root@YOUR_SERVER_IP
cd /tmp/overleaf-deploy
chmod +x *.sh
```

### 2. 一键部署

```bash
# 自签名证书 + IP 访问
./deploy-all.sh \
  --ip YOUR_PUBLIC_IP \
  --github-token ghp_xxxxxxxxxxxx \
  --github-user your-github-username

# 或：Let's Encrypt + 域名访问
./deploy-all.sh \
  --ip YOUR_PUBLIC_IP \
  --domain latex.example.com \
  --github-token ghp_xxxxxxxxxxxx \
  --github-user your-github-username \
  --tls-mode letsencrypt \
  --admin-email admin@example.com
```

### 3. 首次配置

1. 浏览器打开 `https://YOUR_DOMAIN_OR_IP/launchpad`
2. 创建管理员账号
3. 创建第一个 project
4. 等待自动同步或手动执行 `/home/dchen/projects/overleaf/scripts/manual-sync.sh`

## 参数说明

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `--ip` | 是 | - | 服务器公网 IP |
| `--github-token` | 是 | - | GitHub PAT (需 repo 权限) |
| `--github-user` | 是 | - | GitHub 用户名/组织名 |
| `--domain` | 否 | - | 域名 (无则用 IP) |
| `--admin-email` | 否 | admin@example.com | 管理员邮箱 |
| `--tls-mode` | 否 | self-signed | `self-signed` 或 `letsencrypt` |
| `--sync-interval` | 否 | 30 | GitHub 同步间隔(分钟) |
| `--base-dir` | 否 | /home/dchen/projects/overleaf | 安装根目录 |

## 目录结构

```
/home/dchen/projects/overleaf/
├── overleaf-toolkit/       # Overleaf Toolkit (docker-compose 管理)
│   ├── bin/                # 管理脚本 (up/stop/logs/shell)
│   └── config/             # 运行配置
│       ├── overleaf.rc
│       ├── variables.env
│       ├── version
│       └── nginx/certs/    # TLS 证书
├── data/
│   ├── sharelatex/         # Overleaf 项目数据
│   ├── mongo/              # MongoDB 数据
│   └── redis/              # Redis 数据
├── github-repos/           # 每个 project 的本地 git 仓库
│   ├── my-paper-64a1b2.../
│   └── thesis-72c3d4.../
├── github-sync/
│   ├── project-repo-mapping.json  # 项目↔仓库映射
│   └── .git-credentials           # GitHub 凭证
├── scripts/
│   ├── overleaf-github-sync.sh    # 核心同步脚本
│   ├── manual-sync.sh             # 手动同步入口
│   ├── manage-users.sh            # 用户管理工具
│   └── import-from-github.sh      # GitHub → Overleaf 回导
└── logs/
    └── github-sync.log            # 同步日志
```

## 日常管理

### 服务管理

```bash
cd /home/dchen/projects/overleaf/overleaf-toolkit

bin/up -d              # 启动
bin/stop               # 停止
bin/logs -f web        # 查看日志
bin/docker-compose ps  # 服务状态
bin/shell              # 进入容器 shell
```

### 用户管理

```bash
/home/dchen/projects/overleaf/scripts/manage-users.sh create alice@example.com
/home/dchen/projects/overleaf/scripts/manage-users.sh create boss@example.com --admin
/home/dchen/projects/overleaf/scripts/manage-users.sh batch-create users.txt
/home/dchen/projects/overleaf/scripts/manage-users.sh list
```

### GitHub 同步

```bash
# 手动同步所有项目
/home/dchen/projects/overleaf/scripts/manual-sync.sh

# 预览模式（不实际推送）
/home/dchen/projects/overleaf/scripts/manual-sync.sh --dry-run

# 同步单个项目
/home/dchen/projects/overleaf/scripts/manual-sync.sh --project-id 64a1b2c3d4e5f6

# 查看同步日志
tail -f /home/dchen/projects/overleaf/logs/github-sync.log
```

## 多人协作工作流

### 方式一：在线协作（推荐）
多人通过浏览器直接访问同一个 Overleaf project，支持实时编辑。

### 方式二：GitHub 协作
1. 同步脚本定时将 Overleaf 内容推送到 GitHub
2. 团队成员 `git clone` 对应的 GitHub repo
3. 本地编辑 LaTeX 文件，提交 PR
4. 合并后使用 `import-from-github.sh` 回导到 Overleaf

## 故障排查

### 服务无法启动
```bash
cd /home/dchen/projects/overleaf/overleaf-toolkit
bin/doctor         # 运行诊断
bin/logs -f        # 查看完整日志
```

### NGINX 端口冲突
确保 `OVERLEAF_LISTEN_IP:OVERLEAF_PORT` 与 `NGINX_HTTP_LISTEN_IP:NGINX_HTTP_PORT` 不重叠。默认配置下 Overleaf 绑定 `127.0.0.1:8080`，NGINX 绑定 `0.0.0.0:80/443`。

### GitHub 同步失败
```bash
# 检查 Token 是否有效
curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/user

# 检查 MongoDB 连通性
docker exec mongo mongosh --eval "db.adminCommand('ping')"

# 手动运行同步查看错误
/home/dchen/projects/overleaf/scripts/manual-sync.sh 2>&1 | tee /tmp/sync-debug.log
```

### 数据备份与恢复
```bash
# 备份
tar czf overleaf-backup-$(date +%Y%m%d).tar.gz /home/dchen/projects/overleaf/data/

# MongoDB 备份
docker exec mongo mongodump --out /data/db/backup/
docker cp mongo:/data/db/backup/ ./mongo-backup/
```

## 脚本清单

| 脚本 | 说明 |
|------|------|
| `deploy-all.sh` | 一键部署主入口 |
| `01-server-setup.sh` | 服务器环境准备 |
| `02-deploy-overleaf.sh` | Toolkit 部署与配置 |
| `03-setup-tls.sh` | TLS 证书配置 |
| `04-setup-github-sync.sh` | GitHub 同步初始化 |
| `05-setup-cron.sh` | 定时任务配置 |
| `06-setup-collaboration.sh` | 多人协作工具 |
| `overleaf-github-sync.sh` | 核心同步脚本 |
