#!/bin/bash
set -euo pipefail

######################################################################
# 04-setup-github-sync.sh
# GitHub 同步系统初始化：目录结构、凭证配置、mapping 文件
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

if [[ -z "${GITHUB_TOKEN}" ]]; then
  err "请设置 GITHUB_TOKEN 环境变量 (需要 repo 权限)"
fi
if [[ -z "${GITHUB_USER}" ]]; then
  err "请设置 GITHUB_USER 环境变量 (GitHub 用户名或组织名)"
fi

log "===== GitHub 同步系统初始化 ====="

# ---------- 1. 创建目录 ----------
mkdir -p "${SYNC_DIR}" "${REPOS_DIR}" "${SCRIPTS_DIR}" "${LOGS_DIR}"

# ---------- 2. 配置 Git 凭证（仅作用于同步 repo，不修改全局 git 配置）----------
log "配置 Git 凭证..."

# 使用项目级 gitconfig，不污染全局 ~/.gitconfig
GIT_CONFIG_FILE="${SYNC_DIR}/.gitconfig"
git config -f "${GIT_CONFIG_FILE}" user.name "Overleaf Sync Bot"
git config -f "${GIT_CONFIG_FILE}" user.email "overleaf-sync@localhost"
git config -f "${GIT_CONFIG_FILE}" init.defaultBranch main

CREDENTIAL_FILE="${SYNC_DIR}/.git-credentials"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${CREDENTIAL_FILE}"
chmod 600 "${CREDENTIAL_FILE}"
git config -f "${GIT_CONFIG_FILE}" credential.helper "store --file=${CREDENTIAL_FILE}"

log "Git 配置文件: ${GIT_CONFIG_FILE}（不影响全局 git 配置）"

# ---------- 3. 创建 mapping 配置文件 ----------
MAPPING_FILE="${SYNC_DIR}/project-repo-mapping.json"
if [[ ! -f "${MAPPING_FILE}" ]]; then
  log "创建项目-仓库映射配置文件..."
  cat > "${MAPPING_FILE}" << MAPEOF
{
  "github_user": "${GITHUB_USER}",
  "github_token_file": "${CREDENTIAL_FILE}",
  "default_visibility": "${REPO_VISIBILITY}",
  "repo_prefix": "overleaf-",
  "projects": {}
}
MAPEOF
  chmod 600 "${MAPPING_FILE}"
else
  log "映射配置文件已存在，跳过创建"
fi

# ---------- 4. 拷贝核心同步脚本 ----------
SYNC_SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/overleaf-github-sync.sh"
SYNC_SCRIPT_DST="${SCRIPTS_DIR}/overleaf-github-sync.sh"

# 解析真实路径，避免源和目标相同时 cp 报错
SYNC_SCRIPT_SRC_REAL="$(readlink -f "${SYNC_SCRIPT_SRC}" 2>/dev/null || echo "${SYNC_SCRIPT_SRC}")"
SYNC_SCRIPT_DST_REAL="$(readlink -f "${SYNC_SCRIPT_DST}" 2>/dev/null || echo "${SYNC_SCRIPT_DST}")"

if [[ "${SYNC_SCRIPT_SRC_REAL}" == "${SYNC_SCRIPT_DST_REAL}" ]]; then
  chmod +x "${SYNC_SCRIPT_DST}"
  log "同步脚本源和目标为同一文件，跳过拷贝: ${SYNC_SCRIPT_DST}"
elif [[ -f "${SYNC_SCRIPT_SRC}" ]]; then
  cp "${SYNC_SCRIPT_SRC}" "${SYNC_SCRIPT_DST}"
  chmod +x "${SYNC_SCRIPT_DST}"
  log "同步脚本已安装到: ${SYNC_SCRIPT_DST}"
else
  log "警告: 未找到 overleaf-github-sync.sh，请手动拷贝"
fi

# ---------- 5. 验证 GitHub Token ----------
log "验证 GitHub Token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/user")

if [[ "${HTTP_CODE}" == "200" ]]; then
  GH_LOGIN=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/user" | jq -r '.login')
  log "GitHub Token 验证成功，用户: ${GH_LOGIN}"
else
  err "GitHub Token 验证失败 (HTTP ${HTTP_CODE})，请检查 Token 是否有效且具有 repo 权限"
fi

log "===== GitHub 同步系统初始化完成 ====="
log "同步目录: ${SYNC_DIR}"
log "仓库目录: ${REPOS_DIR}"
log "映射文件: ${MAPPING_FILE}"
