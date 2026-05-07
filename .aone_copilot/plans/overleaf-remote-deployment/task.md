### overleaf-remote-deployment ###
# 修复任务清单

- [x] 修改 `02-deploy-overleaf.sh` 中 MongoDB 版本从 6.0 改为 8.0
- [x] 创建 `redeploy.sh` 安全重部署脚本（保留数据、重新生成配置、重启容器）
- [x] 服务器手动验证：同步脚本到服务器并执行 `redeploy.sh`，确认 sharelatex 容器正常运行


updateAtTime: 2026/5/7 12:57:47

planId: abbd708b-8406-4a32-8b1f-75f7614c0ddf