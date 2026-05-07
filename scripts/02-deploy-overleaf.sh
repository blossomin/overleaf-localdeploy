#!/bin/bash
set -euo pipefail

######################################################################
# 02-deploy-overleaf.sh
# 克隆 Overleaf Toolkit 并生成配置文件
# 参数通过环境变量传入（由 deploy-all.sh 设置）
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ---- 派生变量 ----
SITE_URL="${DOMAIN:+https://${DOMAIN}}"
SITE_URL="${SITE_URL:-https://${PUBLIC_IP}}"

if [[ -z "${PUBLIC_IP}" && -z "${DOMAIN}" ]]; then
  err "请设置 PUBLIC_IP 或 DOMAIN 环境变量"
fi

log "===== 部署 Overleaf Toolkit ====="

# ---------- 1. 克隆 Toolkit ----------
if [[ -d "${TOOLKIT_DIR}" ]]; then
  log "1/4 Toolkit 目录已存在，拉取最新代码..."
  cd "${TOOLKIT_DIR}" && git pull --ff-only || true
else
  log "1/4 克隆 Overleaf Toolkit..."
  git clone https://github.com/overleaf/toolkit.git "${TOOLKIT_DIR}"
fi

cd "${TOOLKIT_DIR}"

# ---------- 2. 初始化配置（含 TLS） ----------
log "2/4 初始化配置..."
# bin/init 在配置已存在时会报错退出，这是安全的——忽略即可
# 后续步骤会用 cat > 覆写 overleaf.rc 和 variables.env
bin/init --tls 2>/dev/null || bin/init 2>/dev/null || {
  log "配置文件已存在，跳过 init（后续步骤会覆写配置）"
}
# 无论 init 是否成功，确保必要的目录和文件存在
mkdir -p config/nginx/certs
# 设置 docker 镜像版本
echo "6.1.2" > config/version
log "已设置 config/version = 6.1.2"

# 构建自定义镜像（包含学术论文常用 TexLive 宏包）
CUSTOM_IMAGE="rakusa/sharelatex-custom:6.1.2"
if ! docker image inspect "${CUSTOM_IMAGE}" >/dev/null 2>&1; then
  log "构建自定义 TexLive 镜像（首次需要 10-20 分钟）..."
  docker build -f "${SCRIPT_DIR}/Dockerfile.custom-texlive" -t "${CUSTOM_IMAGE}" "${SCRIPT_DIR}"
else
  log "自定义镜像已存在: ${CUSTOM_IMAGE}，跳过构建"
fi

# 通过 docker-compose.override.yml 覆盖默认镜像
cat > config/docker-compose.override.yml << OVERRIDEEOF
---
services:
  sharelatex:
    image: ${CUSTOM_IMAGE}
OVERRIDEEOF
log "已配置 docker-compose.override.yml 使用 ${CUSTOM_IMAGE}"

# ---------- 3. 生成 overleaf.rc ----------
log "3/4 生成 config/overleaf.rc..."
cat > config/overleaf.rc << RCEOF
# ====== Overleaf Toolkit 配置文件 ======
# 由部署脚本自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

# --- 基础配置 ---
PROJECT_NAME=overleaf
SERVER_PRO=false

# --- 数据持久化（绝对路径）---
OVERLEAF_DATA_PATH=${OVERLEAF_BASE_DIR}/data/sharelatex

# --- 监听配置 ---
# Overleaf 仅绑定 localhost，由 NGINX 反向代理对外
OVERLEAF_LISTEN_IP=127.0.0.1
OVERLEAF_PORT=${OVERLEAF_PORT}

# --- 日志 ---
OVERLEAF_LOG_PATH=${OVERLEAF_BASE_DIR}/logs

# --- MongoDB ---
MONGO_ENABLED=true
MONGO_IMAGE=mongo
MONGO_VERSION=8.0
MONGO_DATA_PATH=${OVERLEAF_BASE_DIR}/data/mongo

# --- Redis ---
REDIS_ENABLED=true
REDIS_DATA_PATH=${OVERLEAF_BASE_DIR}/data/redis
REDIS_AOF_PERSISTENCE=true

# --- Sibling Containers (禁用，社区版不支持) ---
SIBLING_CONTAINERS_ENABLED=false
DOCKER_SOCKET_PATH=/var/run/docker.sock

# --- Git Bridge (禁用，社区版不支持，使用外部脚本替代) ---
GIT_BRIDGE_ENABLED=false

# --- TLS NGINX 反向代理 ---
NGINX_ENABLED=true
NGINX_CONFIG_PATH=config/nginx/nginx.conf
NGINX_HTTP_LISTEN_IP=0.0.0.0
NGINX_HTTP_PORT=${NGINX_HTTP_PORT}
NGINX_TLS_LISTEN_IP=0.0.0.0
TLS_PORT=${TLS_PORT}
TLS_PRIVATE_KEY_PATH=config/nginx/certs/overleaf_key.pem
TLS_CERTIFICATE_PATH=config/nginx/certs/overleaf_certificate.pem
RCEOF

# ---------- 4. 生成 variables.env ----------
log "4/4 生成 config/variables.env..."
cat > config/variables.env << ENVEOF
# ====== Overleaf 环境变量 ======
# 由部署脚本自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

OVERLEAF_APP_NAME=My Overleaf
OVERLEAF_SITE_URL=${SITE_URL}
OVERLEAF_NAV_TITLE=My Overleaf
OVERLEAF_ADMIN_EMAIL=${ADMIN_EMAIL}

# 允许用户自行注册（可按需改为 false）
OVERLEAF_LEFT_FOOTER=[]
OVERLEAF_RIGHT_FOOTER=[]

# 编译超时（秒）
OVERLEAF_COMPILE_TIMEOUT=180

# 关闭邮件验证（小团队自部署无需邮件）
EMAIL_CONFIRMATION_DISABLED=true
ENVEOF

log "===== Overleaf Toolkit 部署配置完成 ====="
log "Toolkit 目录: ${TOOLKIT_DIR}"
log "数据目录: ${OVERLEAF_BASE_DIR}/data/"
log "站点地址: ${SITE_URL}"
log ""
log "注意：请先完成 TLS 证书配置 (03-setup-tls.sh) 后再启动服务"
