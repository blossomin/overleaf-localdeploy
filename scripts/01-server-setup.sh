#!/bin/bash
set -euo pipefail

######################################################################
# 01-server-setup.sh
# 远端服务器环境准备：安装 Docker、Docker Compose、基础工具、防火墙
# 适用于 Ubuntu 22.04+ / Debian 12+
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ---------- 检查 root ----------
if [[ $EUID -ne 0 ]]; then
  err "请使用 root 用户或 sudo 运行此脚本"
fi

log "===== 服务器环境准备开始 ====="

# ---------- 1. 系统更新 ----------
log "1/6 更新系统包..."
apt-get update -qq
apt-get upgrade -y -qq

# ---------- 2. 安装基础工具 ----------
log "2/6 安装基础工具 (git, curl, jq, unzip, ca-certificates)..."
apt-get install -y -qq \
  git curl wget jq unzip zip \
  ca-certificates gnupg lsb-release \
  software-properties-common \
  coreutils openssl

# ---------- 3. 安装 Docker ----------
if command -v docker &>/dev/null; then
  log "3/6 Docker 已安装，跳过"
  docker --version
else
  log "3/6 安装 Docker..."
  # 添加 Docker 官方 GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # 添加 Docker 源
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "Docker 安装完成"
  docker --version
fi

# ---------- 4. Docker Compose 检查 ----------
if docker compose version &>/dev/null; then
  log "4/6 Docker Compose 已可用"
  docker compose version
else
  err "Docker Compose plugin 未安装，请检查 Docker 安装"
fi

# ---------- 5. 创建工作目录 ----------
log "5/6 创建 Overleaf 工作目录..."
mkdir -p "${OVERLEAF_BASE_DIR}"/{data/sharelatex,data/mongo,data/redis,github-repos,scripts,logs}
log "工作目录: ${OVERLEAF_BASE_DIR}"

# ---------- 6. 端口检查（不配置防火墙）----------
log "6/6 检查端口占用..."
for port in ${TLS_PORT} ${NGINX_HTTP_PORT}; do
  [[ -z "${port}" ]] && continue
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    log "警告: 端口 ${port} 已被占用，可能导致 NGINX 启动失败"
  fi
done
log "请确保以下端口可访问: ${TLS_PORT}/tcp (HTTPS)${NGINX_HTTP_PORT:+, ${NGINX_HTTP_PORT}/tcp (HTTP)}"

log "===== 服务器环境准备完成 ====="
log "Docker: $(docker --version)"
log "Docker Compose: $(docker compose version)"
log "工作目录: ${OVERLEAF_BASE_DIR}"
