#!/bin/bash
set -euo pipefail

######################################################################
# redeploy.sh
# 安全重部署：保留数据，重新生成配置，重启所有容器
#
# 用法:
#   ./redeploy.sh              # 重新生成配置并重启
#   ./redeploy.sh --skip-tls   # 跳过 TLS 证书重新生成
#
# 安全保障：
#   - 使用 bin/stop 停止容器，绝不使用 docker-compose down -v
#   - 绝不删除 data/ 目录（MongoDB、Redis、ShareLaTeX 数据）
#   - 仅重新生成 overleaf.rc / variables.env 配置文件
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

SKIP_TLS=false
[[ "${1:-}" == "--skip-tls" ]] && SKIP_TLS=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ---- 安全检查：确认数据目录存在 ----
DATA_DIR="${OVERLEAF_BASE_DIR}/data"
if [[ -d "${DATA_DIR}" ]]; then
  log "数据目录存在: ${DATA_DIR} — 数据将被完整保留"
  log "  MongoDB: ${DATA_DIR}/mongo"
  log "  Redis:   ${DATA_DIR}/redis"
  log "  Overleaf: ${DATA_DIR}/sharelatex"
else
  log "数据目录不存在，将在启动时自动创建: ${DATA_DIR}"
fi

# ---- 安全检查：确认 toolkit 目录存在 ----
if [[ ! -d "${TOOLKIT_DIR}" ]]; then
  err "Toolkit 目录不存在: ${TOOLKIT_DIR}，请先运行完整部署 deploy-all.sh"
fi

echo ""
echo "============================================"
echo "  安全重部署（保留所有数据）"
echo "============================================"
echo "  Toolkit:  ${TOOLKIT_DIR}"
echo "  数据目录: ${DATA_DIR}"
echo "  跳过TLS:  ${SKIP_TLS}"
echo "============================================"
echo ""

# ======== Step 1: 停止容器（不删除 volume）========
log "Step 1/4: 停止所有容器..."
cd "${TOOLKIT_DIR}"
bin/stop 2>/dev/null || {
  log "bin/stop 失败，尝试 docker compose stop..."
  bin/docker-compose stop 2>/dev/null || true
}
log "容器已停止"

# ======== Step 2: 重新生成配置 ========
log "Step 2/4: 重新生成 overleaf.rc 和 variables.env..."
bash "${SCRIPT_DIR}/02-deploy-overleaf.sh"
log "配置已重新生成"

# ======== Step 3: TLS 证书 ========
if [[ "${SKIP_TLS}" == "true" ]]; then
  log "Step 3/4: 跳过 TLS 证书生成（--skip-tls）"
else
  log "Step 3/4: 重新生成 TLS 证书..."
  bash "${SCRIPT_DIR}/03-setup-tls.sh"
  log "TLS 证书已更新"
fi

# ======== Step 4: 启动容器 ========
log "Step 4/4: 启动所有容器..."
cd "${TOOLKIT_DIR}"
bin/docker-compose pull
bin/up -d

# ---- 等待服务就绪 ----
SITE="${DOMAIN:-${PUBLIC_IP}}"
# 非标准端口时需要在 URL 中加上端口号
if [[ "${TLS_PORT}" == "443" ]]; then
  SITE_URL="https://${SITE}"
else
  SITE_URL="https://${SITE}:${TLS_PORT}"
fi
log "等待服务就绪 (最多 120 秒)... ${SITE_URL}"
READY=false
for i in $(seq 1 24); do
  if curl -sk "${SITE_URL}/" >/dev/null 2>&1; then
    READY=true
    break
  fi
  echo "  等待中... (${i}/24)"
  sleep 5
done

echo ""
if [[ "${READY}" == "true" ]]; then
  log "Overleaf 服务已就绪!"
else
  log "警告: 服务未在 120 秒内就绪，请检查日志:"
  log "  docker logs --tail 30 sharelatex"
fi

# ---- 验证容器状态 ----
echo ""
log "容器状态:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "sharelatex|mongo|redis|nginx" || true

echo ""
log "重部署完成！数据已完整保留。"
log "访问: ${SITE_URL}"
