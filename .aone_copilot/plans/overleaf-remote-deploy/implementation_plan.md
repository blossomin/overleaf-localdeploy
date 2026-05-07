### overleaf-remote-deploy ###
基于 Overleaf Toolkit 在远端 Linux 服务器上部署 Overleaf 社区版，配置公网 IP 访问、数据持久化、GitHub 备份与多人协作（通过 git 同步项目）。

# 远端服务器部署 Overleaf 社区版 + GitHub 备份 + 多人协作方案

本方案在远端 Linux 服务器上部署 Overleaf Community Edition，实现公网 IP 访问、项目数据持久化、GitHub 仓库备份，以及通过 git 实现多人协作。

## User Review Required

> [!IMPORTANT]
> 1. 社区版（CE）**不支持**官方 Git Bridge 功能（仅 Server Pro），因此本方案通过**定时脚本 + GitHub 推送**实现项目备份与多人协作。
> 2. 公网 IP 直接暴露 HTTP 80 端口存在安全风险，建议后续考虑配置 TLS（HTTPS）或使用防火墙限制来源 IP。
> 3. 多人协作方案：Overleaf CE 本身支持多用户注册和**实时协作编辑**（同一个 Overleaf 实例上的用户可以同时编辑同一项目），git 同步仅作为**外部备份和版本管理**的补充。

## Proposed Changes

### 1. 远端服务器环境准备

在远端服务器上安装 Docker 和必要依赖。

#### 脚本内容：`01-prepare-server.sh`
- 安装 Docker Engine（官方源）
- 安装 Docker Compose plugin
- 安装 git、coreutils
- 配置防火墙开放 80 端口（或自定义端口）
- 创建工作目录 `/opt/overleaf`

---

### 2. 部署 Overleaf Toolkit

使用 Overleaf Toolkit 部署社区版。

#### 脚本内容：`02-deploy-overleaf.sh`
- 克隆 toolkit 仓库到 `/opt/overleaf/overleaf-toolkit`
- 运行 `bin/init` 初始化配置
- 修改 `config/overleaf.rc`：
  - `OVERLEAF_LISTEN_IP=0.0.0.0`（允许公网访问）
  - `OVERLEAF_PORT=80`（或自定义端口如 8080）
  - `OVERLEAF_DATA_PATH=/opt/overleaf/data/sharelatex`（持久化到宿主机固定路径）
  - `MONGO_DATA_PATH=/opt/overleaf/data/mongo`
  - `REDIS_DATA_PATH=/opt/overleaf/data/redis`
- 修改 `config/variables.env`：
  - 设置 `OVERLEAF_APP_NAME` 自定义站点名称
  - 设置 `OVERLEAF_SITE_URL=http://<YOUR_PUBLIC_IP>`
- 启动服务 `bin/up -d`
- 输出管理员注册地址

---

### 3. 数据持久化 & MongoDB 备份

确保数据安全持久化，并配置自动备份。

#### 脚本内容：`03-setup-backup.sh`
- 创建 MongoDB 备份脚本 `/opt/overleaf/scripts/mongo-backup.sh`
  - 使用 `mongodump` 通过 `docker exec` 导出数据
  - 备份至 `/opt/overleaf/backups/mongo/` 并保留最近 7 天
- 创建项目文件备份脚本（tar 打包 sharelatex data）
- 配置 crontab 每日自动备份

---

### 4. GitHub 仓库备份 & 多人协作

将 Overleaf 项目数据同步到 GitHub 仓库，实现版本管理和多人协作。

#### 脚本内容：`04-setup-github-sync.sh`
- 在 `/opt/overleaf/overleaf-projects-git` 初始化 git 仓库
- 配置 GitHub remote（需要用户提供 GitHub 仓库地址和 token）
- 创建同步脚本 `/opt/overleaf/scripts/sync-to-github.sh`：
  - 从 Overleaf data 目录提取项目源文件（`.tex`, `.bib`, `.cls` 等）
  - 按项目名/ID 组织目录结构
  - 自动 commit & push 到 GitHub
- 配置 crontab 定时同步（每小时）
- 提供手动触发命令

---

### 5. 多人协作配置

配置 Overleaf CE 支持多人注册和协作。

#### 脚本内容：`05-setup-collaboration.sh`
- 在 `variables.env` 中启用邮件邀请（可选，需 SMTP）
- 或配置开放注册模式，允许团队成员自行注册
- 提供创建用户的 CLI 命令（通过 `bin/shell` 进入容器执行）
- 输出协作使用指南

---

### 6. 一键部署主脚本

将以上步骤整合为一个主入口脚本。

#### [NEW] `deploy.sh`
- 交互式收集配置信息（公网 IP、GitHub 仓库地址、GitHub Token 等）
- 依次调用上述 5 个脚本
- 输出部署摘要和访问地址

---

## Verification Plan

### Automated Tests
```bash
# 检查 Docker 服务状态
docker ps | grep sharelatex

# 检查 Overleaf 是否可访问
curl -s -o /dev/null -w "%{http_code}" http://<PUBLIC_IP>/

# 检查 MongoDB 备份是否生成
ls -la /opt/overleaf/backups/mongo/

# 检查 GitHub 同步是否工作
cd /opt/overleaf/overleaf-projects-git && git log --oneline -5
```

### Manual Verification
- 通过浏览器打开 `http://<PUBLIC_IP>/launchpad` 注册管理员账号
- 创建测试项目，验证 LaTeX 编译
- 邀请第二个用户，验证实时协作编辑
- 手动触发 GitHub 同步，验证 GitHub 仓库中出现项目文件
- 重启服务器后验证数据持久化（项目仍在）

updateAtTime: 2026/5/7 10:31:40

planId: abbd708b-8406-4a32-8b1f-75f7614c0ddf