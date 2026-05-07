#!/bin/bash
set -euo pipefail

######################################################################
# deploy-all.sh
# 一键部署 Overleaf 社区版 + TLS NGINX + GitHub 多仓库同步
#
# 用法:
#   ./deploy-all.sh \
#     --ip YOUR_PUBLIC_IP \
#     --domain YOUR_DOMAIN \
#     --github-token ghp_xxxx \
#     --github-user your-username \
#     --admin-email admin@example.com \
#     --tls-mode self-signed \
#     --sync-interval 30
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 从 env.conf 加载默认值 ----
source "${SCRIPT_DIR}/env.conf"

# ---- 兜底默认值（防止 env.conf 中缺少某些变量）----
: "${TLS_PORT:=443}"
: "${NGINX_HTTP_PORT:=80}"
: "${OVERLEAF_PORT:=8080}"
: "${TLS_MODE:=self-signed}"
: "${ADMIN_EMAIL:=admin@example.com}"
: "${SYNC_INTERVAL:=30}"
: "${REPO_VISIBILITY:=private}"

# ---- 帮助信息 ----
usage() {
  cat << EOF
一键部署 Overleaf 社区版 + GitHub 同步

用法: $0 [选项]

必填参数:
  --ip <IP>              服务器公网 IP
  --github-token <TOKEN> GitHub Personal Access Token (需 repo 权限)
  --github-user <USER>   GitHub 用户名或组织名

可选参数:
  --domain <DOMAIN>      域名 (如有，用于 TLS 证书)
  --admin-email <EMAIL>  管理员邮箱 (默认: admin@example.com)
  --tls-mode <MODE>      TLS 模式: self-signed | letsencrypt (默认: self-signed)
  --tls-port <PORT>      HTTPS 端口 (默认: ${TLS_PORT:-443})
  --http-port <PORT>     HTTP 重定向端口 (默认: ${NGINX_HTTP_PORT:-80})
  --overleaf-port <PORT> Overleaf 内部端口 (默认: ${OVERLEAF_PORT:-8080})
  --sync-interval <MIN>  GitHub 同步间隔分钟数 (默认: 30)
  --base-dir <DIR>       Overleaf 安装目录 (默认: ${OVERLEAF_BASE_DIR})
  --help                 显示帮助

示例:
  # 自签名证书 + 纯 IP 访问
  $0 --ip 1.2.3.4 --github-token ghp_xxx --github-user myuser

  # Let's Encrypt + 域名访问
  $0 --ip 1.2.3.4 --domain latex.example.com \\
     --github-token ghp_xxx --github-user myuser \\
     --tls-mode letsencrypt --admin-email me@example.com
EOF
}

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)             PUBLIC_IP="$2"; shift 2 ;;
    --domain)         DOMAIN="$2"; shift 2 ;;
    --github-token)   GITHUB_TOKEN="$2"; shift 2 ;;
    --github-user)    GITHUB_USER="$2"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="$2"; shift 2 ;;
    --tls-mode)       TLS_MODE="$2"; shift 2 ;;
    --tls-port)       TLS_PORT="$2"; shift 2 ;;
    --http-port)      NGINX_HTTP_PORT="$2"; shift 2 ;;
    --overleaf-port)  OVERLEAF_PORT="$2"; shift 2 ;;
    --sync-interval)  SYNC_INTERVAL="$2"; shift 2 ;;
    --base-dir)       OVERLEAF_BASE_DIR="$2"; shift 2 ;;
    --help)           usage; exit 0 ;;
    *)                echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

# ---- 参数校验 ----
ERRORS=()
[[ -z "${PUBLIC_IP}" ]]     && ERRORS+=("缺少 --ip")
[[ -z "${GITHUB_TOKEN}" ]]  && ERRORS+=("缺少 --github-token")
[[ -z "${GITHUB_USER}" ]]   && ERRORS+=("缺少 --github-user")

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "错误:" >&2
  for e in "${ERRORS[@]}"; do echo "  - $e" >&2; done
  echo "" >&2
  usage
  exit 1
fi

# ---- 执行确认 ----
SITE="${DOMAIN:-${PUBLIC_IP}}"
cat << CONFIRM

============================================
  Overleaf 一键部署配置确认
============================================
  公网 IP:       ${PUBLIC_IP}
  域名:          ${DOMAIN:-（无，使用 IP 访问）}
  站点地址:      https://${SITE}
  TLS 模式:      ${TLS_MODE}
  GitHub 用户:   ${GITHUB_USER}
  管理员邮箱:    ${ADMIN_EMAIL}
  同步间隔:      每 ${SYNC_INTERVAL} 分钟
  安装目录:      ${OVERLEAF_BASE_DIR}
============================================

CONFIRM

read -rp "确认以上配置开始部署？(y/N) " confirm
[[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && { echo "已取消"; exit 0; }

log() { echo ""; echo "================================================================"; echo "[DEPLOY] $*"; echo "================================================================"; }

# ---- 将敏感信息写入 env.secret（不入 git）----
cat > "${SCRIPT_DIR}/env.secret" << SECRETEOF
######################################################################
# env.secret - 敏感配置（不入 git）
# 由 deploy-all.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
######################################################################
export GITHUB_TOKEN="${GITHUB_TOKEN}"
export PUBLIC_IP="${PUBLIC_IP}"
export DOMAIN="${DOMAIN}"
export ADMIN_EMAIL="${ADMIN_EMAIL}"
export GITHUB_USER="${GITHUB_USER}"
SECRETEOF
chmod 600 "${SCRIPT_DIR}/env.secret"

# ---- 将非敏感配置回写到 env.conf（可安全提交 git）----
cat > "${SCRIPT_DIR}/env.conf" << ENVCONFEOF
######################################################################
# env.conf - Overleaf 部署全局环境变量配置（可安全提交到 git）
# 所有脚本启动时会自动 source 此文件
# 敏感信息在 env.secret 中，不要在此文件写入 Token 等敏感值
# 由 deploy-all.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
######################################################################

# ---- 加载敏感配置（env.secret 不入 git）----
SCRIPT_DIR_CONF="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "\${SCRIPT_DIR_CONF}/env.secret" ]]; then
  source "\${SCRIPT_DIR_CONF}/env.secret"
fi

# ---- 基础路径 ----
export OVERLEAF_BASE_DIR="${OVERLEAF_BASE_DIR}"

# ---- Overleaf 服务端口 ----
export OVERLEAF_PORT="${OVERLEAF_PORT}"

# ---- 对外端口 ----
export TLS_PORT="${TLS_PORT}"
export NGINX_HTTP_PORT="${NGINX_HTTP_PORT}"

# ---- 网络配置（非敏感值从 env.secret 加载，这里提供兜底默认值）----
export PUBLIC_IP="\${PUBLIC_IP:-}"
export DOMAIN="\${DOMAIN:-}"
export ADMIN_EMAIL="\${ADMIN_EMAIL:-admin@example.com}"

# ---- TLS 配置 ----
export TLS_MODE="${TLS_MODE}"

# ---- GitHub 同步配置（Token 从 env.secret 加载）----
export GITHUB_USER="\${GITHUB_USER:-}"
export REPO_VISIBILITY="${REPO_VISIBILITY:-private}"
export SYNC_INTERVAL="${SYNC_INTERVAL}"

# ======== 派生路径（自动计算，通常无需修改）========
export TOOLKIT_DIR="\${OVERLEAF_BASE_DIR}/overleaf-toolkit"
export SYNC_DIR="\${OVERLEAF_BASE_DIR}/github-sync"
export REPOS_DIR="\${OVERLEAF_BASE_DIR}/github-repos"
export SCRIPTS_DIR="\${OVERLEAF_BASE_DIR}/scripts"
export LOGS_DIR="\${OVERLEAF_BASE_DIR}/logs"
ENVCONFEOF

log "env.conf + env.secret 已更新"

# ---- 重新 source 以加载完整配置 ----
source "${SCRIPT_DIR}/env.conf"

# ======== Step 1: 服务器环境准备 ========
log "Step 1/6: 服务器环境准备"
bash "${SCRIPT_DIR}/01-server-setup.sh"

# ======== Step 2: 部署 Overleaf Toolkit ========
log "Step 2/6: 部署 Overleaf Toolkit"
bash "${SCRIPT_DIR}/02-deploy-overleaf.sh"

# ======== Step 3: TLS 证书配置 ========
log "Step 3/6: TLS 证书配置"
bash "${SCRIPT_DIR}/03-setup-tls.sh"

# ======== Step 4: 启动 Overleaf ========
log "Step 4/6: 启动 Overleaf 服务"
cd "${TOOLKIT_DIR}"
echo "拉取 Docker 镜像（首次可能较慢）..."
bin/docker-compose pull
echo "启动服务..."
bin/up -d

echo "等待服务就绪 (最多 120 秒)..."
for i in $(seq 1 24); do
  if curl -sk "https://${SITE}/" >/dev/null 2>&1; then
    echo "Overleaf 服务已就绪!"
    break
  fi
  echo "  等待中... (${i}/24)"
  sleep 5
done

# ======== Step 5: GitHub 同步配置 ========
log "Step 5/6: GitHub 同步系统配置"
bash "${SCRIPT_DIR}/04-setup-github-sync.sh"
bash "${SCRIPT_DIR}/05-setup-cron.sh"

# ======== Step 6: 多人协作配置 ========
log "Step 6/6: 多人协作配置"
bash "${SCRIPT_DIR}/06-setup-collaboration.sh"

# ======== 部署完成 ========
echo ""
echo "================================================================"
echo "  部署完成!"
echo "================================================================"
echo ""
echo "  访问 Overleaf:  https://${SITE}"
echo "  创建管理员:     https://${SITE}/launchpad"
echo ""
echo "  管理命令:"
echo "    启动服务:     cd ${TOOLKIT_DIR} && bin/up -d"
echo "    停止服务:     cd ${TOOLKIT_DIR} && bin/stop"
echo "    查看日志:     cd ${TOOLKIT_DIR} && bin/logs -f web"
echo "    服务状态:     cd ${TOOLKIT_DIR} && bin/docker-compose ps"
echo ""
echo "  用户管理:       ${OVERLEAF_BASE_DIR}/scripts/manage-users.sh"
echo "  手动同步:       ${OVERLEAF_BASE_DIR}/scripts/manual-sync.sh"
echo "  同步日志:       ${OVERLEAF_BASE_DIR}/logs/github-sync.log"
echo ""
echo "  首次使用步骤:"
echo "    1. 浏览器打开 https://${SITE}/launchpad 创建管理员账号"
echo "    2. 登录后创建第一个 project"
echo "    3. 等待 ${SYNC_INTERVAL} 分钟后检查 GitHub 仓库"
echo "    4. 或手动执行: ${OVERLEAF_BASE_DIR}/scripts/manual-sync.sh"
echo ""
