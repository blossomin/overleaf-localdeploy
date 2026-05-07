### overleaf-remote-deployment ###
修复 MongoDB 版本不兼容导致 sharelatex 容器不断重启的问题，同时创建安全的"保留数据重新部署"脚本，确保重启/重部署不会丢失已有 Overleaf project 数据。

# 修复 MongoDB 版本兼容性 & 安全重部署方案

## 背景
`sharelatex/sharelatex:6.1.2` 镜像要求 MongoDB >= 8.0，但 `02-deploy-overleaf.sh` 生成的 `overleaf.rc` 配置了 `MONGO_VERSION=6.0`，导致容器启动时检查失败，不断重启。

同时用户要求：重新部署只更新配置和重启容器，**绝不删除已有数据**（MongoDB、Redis、ShareLaTeX data 目录）。

## User Review Required

> [!IMPORTANT]
> MongoDB 从 6.0 升级到 8.0 是跨大版本升级。由于当前系统刚部署、数据量极小（尚未创建管理员账号），直接切换版本是安全的。若后续有大量数据时需要升级 MongoDB，则必须按照 MongoDB 官方文档逐版本升级（6.0 → 7.0 → 8.0）。

> [!WARNING]
> `deploy-all.sh` 的全量重部署流程会重新生成 `overleaf.rc` 和 `variables.env`，但**不会删除** `data/` 目录。需要新增一个轻量的 `redeploy.sh` 脚本，仅执行"停止→重新生成配置→重启"，不重复安装 Docker 等环境。

## Proposed Changes

### 脚本修复

#### [MODIFY] [02-deploy-overleaf.sh](file:///Users/dchen/Desktop/overleaf/scripts/02-deploy-overleaf.sh)
- 将 `MONGO_IMAGE=mongo` + `MONGO_VERSION=6.0` 改为 `MONGO_IMAGE=mongo` + `MONGO_VERSION=8.0`
- 这是 sharelatex 容器不断重启的根因

```diff
 # --- MongoDB ---
 MONGO_ENABLED=true
 MONGO_IMAGE=mongo
-MONGO_VERSION=6.0
+MONGO_VERSION=8.0
 MONGO_DATA_PATH=${OVERLEAF_BASE_DIR}/data/mongo
```

---

#### [NEW] [redeploy.sh](file:///Users/dchen/Desktop/overleaf/scripts/redeploy.sh)
创建安全的"保留数据重新部署"脚本，核心逻辑：
1. 加载 `env.conf` + `env.secret`
2. **停止所有容器**（`bin/stop`），不执行 `bin/docker-compose down -v`（不删 volume）
3. 重新生成 `overleaf.rc` 和 `variables.env`（调用 `02-deploy-overleaf.sh`）
4. 重新生成 TLS 证书（调用 `03-setup-tls.sh`，证书覆盖是安全的）
5. **重新启动**（`bin/up -d`）
6. 等待服务就绪
7. 跳过 01（环境安装）、04-06（同步/cron/协作）— 这些是一次性配置

关键安全保障：
- 脚本开头显式检查 `data/` 目录存在且不为空
- 使用 `bin/stop` 而非 `docker-compose down -v`
- 绝不执行 `rm -rf` 对 data 目录

---

#### [MODIFY] [04-setup-github-sync.sh](file:///Users/dchen/Desktop/overleaf/scripts/04-setup-github-sync.sh)
- 已在上一轮修复，添加了 `readlink -f` 路径对比，源和目标相同时跳过 cp
- 本次无需再改

## Verification Plan

### Manual Verification
1. 将修改后的脚本同步到服务器
2. 在服务器上执行 `redeploy.sh`
3. 验证：
   - `docker ps` 所有 4 个容器（sharelatex、mongo、redis、nginx）都是 Up 状态
   - `docker logs sharelatex` 无 MongoDB 版本报错
   - 浏览器访问 `https://<IP>` 能打开 Overleaf 页面
   - 如有已创建的 project，数据仍然存在


updateAtTime: 2026/5/7 12:57:47

planId: abbd708b-8406-4a32-8b1f-75f7614c0ddf