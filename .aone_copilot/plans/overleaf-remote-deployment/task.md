### overleaf-remote-deployment ###
# 远端部署 Overleaf + GitHub 同步 任务清单

## 脚本开发

- [x] 编写 `01-server-setup.sh` - 服务器环境准备（Docker/防火墙）
- [x] 编写 `02-deploy-overleaf.sh` - 克隆 toolkit、生成 overleaf.rc / variables.env / version 配置
- [x] 编写 `03-setup-tls.sh` - TLS 证书配置（自签名 + Let's Encrypt 两种模式）
- [x] 编写 `04-setup-github-sync.sh` - GitHub 同步系统初始化（目录、凭证、mapping 文件）
- [x] 编写 `overleaf-github-sync.sh` - 核心同步脚本（MongoDB 查询 → 导出 → git push）
- [x] 编写 `05-setup-cron.sh` - Cron 定时任务配置
- [x] 编写 `06-setup-collaboration.sh` - 多人协作用户管理脚本
- [x] 编写 `deploy-all.sh` - 一键部署主入口脚本

## 文档

- [x] 编写 `README.md` - 部署说明文档（含参数说明、使用方法、故障排查）


updateAtTime: 2026/5/7 10:38:49

planId: abbd708b-8406-4a32-8b1f-75f7614c0ddf