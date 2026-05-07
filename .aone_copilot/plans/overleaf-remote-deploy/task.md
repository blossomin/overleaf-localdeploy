### overleaf-remote-deploy ###
# 部署任务清单

## 1. 环境准备脚本
- [ ] 创建 `scripts/01-prepare-server.sh` — 安装 Docker、git、配置防火墙

## 2. Overleaf 部署脚本
- [ ] 创建 `scripts/02-deploy-overleaf.sh` — 克隆 toolkit、初始化配置、设置公网访问、启动服务

## 3. 数据备份脚本
- [ ] 创建 `scripts/03-setup-backup.sh` — MongoDB 备份、项目文件备份、crontab 配置

## 4. GitHub 同步脚本
- [ ] 创建 `scripts/04-setup-github-sync.sh` — 初始化 git 仓库、配置 GitHub remote、创建同步脚本和定时任务

## 5. 多人协作配置脚本
- [ ] 创建 `scripts/05-setup-collaboration.sh` — 配置用户注册和协作

## 6. 一键部署主脚本
- [ ] 创建 `scripts/deploy.sh` — 交互式主入口，整合所有步骤

## 7. 部署文档
- [ ] 创建 `scripts/README.md` — 部署指南文档，包含使用说明和注意事项

updateAtTime: 2026/5/7 10:31:40

planId: abbd708b-8406-4a32-8b1f-75f7614c0ddf