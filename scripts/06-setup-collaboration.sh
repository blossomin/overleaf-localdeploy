#!/bin/bash
set -euo pipefail

######################################################################
# 06-setup-collaboration.sh
# 多人协作配置：批量创建用户、协作说明
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

log "===== 多人协作配置 ====="

# ---------- 1. 创建用户管理脚本 ----------
USER_MGMT="${SCRIPTS_DIR}/manage-users.sh"
cat > "${USER_MGMT}" << 'UMEOF'
#!/bin/bash
set -euo pipefail

usage() {
  cat << EOF
Overleaf 用户管理工具

用法:
  $0 create <email> [--admin]     创建用户（返回设置密码的链接）
  $0 batch-create <file>          从文件批量创建（每行一个邮箱）
  $0 list                         列出所有用户
  $0 delete <email>               删除用户

示例:
  $0 create alice@example.com
  $0 create admin@example.com --admin
  $0 batch-create users.txt
  $0 list
EOF
}

CONTAINER="sharelatex"

create_user() {
  local email="$1"
  local is_admin="${2:-false}"

  echo "创建用户: ${email} (admin: ${is_admin})"
  if [[ "${is_admin}" == "true" ]]; then
    docker exec "${CONTAINER}" bash -c "
      cd /overleaf/services/web && \
      node modules/server-ce-scripts/scripts/create-user.mjs \
        --email '${email}' --admin
    "
  else
    docker exec "${CONTAINER}" bash -c "
      cd /overleaf/services/web && \
      node modules/server-ce-scripts/scripts/create-user.mjs \
        --email '${email}'
    "
  fi
  echo ""
  echo "用户 ${email} 已创建。请将上述密码设置链接发送给该用户。"
}

batch_create() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "文件不存在: ${file}" >&2
    exit 1
  fi
  while IFS= read -r email || [[ -n "${email}" ]]; do
    email=$(echo "${email}" | xargs)  # trim whitespace
    [[ -z "${email}" || "${email}" == \#* ]] && continue
    create_user "${email}" "false"
    echo "---"
  done < "${file}"
}

list_users() {
  echo "查询所有用户..."
  docker exec mongo mongosh --quiet --eval "
    use sharelatex;
    db.users.find({}, {email: 1, isAdmin: 1, first_name: 1, last_name: 1}).forEach(u => {
      print(u._id + ' | ' + (u.email || 'N/A') + ' | admin:' + (u.isAdmin || false) + ' | ' + (u.first_name || '') + ' ' + (u.last_name || ''));
    });
  "
}

delete_user() {
  local email="$1"
  echo "删除用户: ${email}"
  docker exec "${CONTAINER}" bash -c "
    cd /overleaf/services/web && \
    node modules/server-ce-scripts/scripts/delete-user.mjs --email '${email}'
  "
  echo "用户 ${email} 已删除"
}

case "${1:-}" in
  create)
    [[ -z "${2:-}" ]] && { usage; exit 1; }
    is_admin="false"
    [[ "${3:-}" == "--admin" ]] && is_admin="true"
    create_user "$2" "${is_admin}"
    ;;
  batch-create)
    [[ -z "${2:-}" ]] && { usage; exit 1; }
    batch_create "$2"
    ;;
  list)
    list_users
    ;;
  delete)
    [[ -z "${2:-}" ]] && { usage; exit 1; }
    delete_user "$2"
    ;;
  *)
    usage
    ;;
esac
UMEOF
chmod +x "${USER_MGMT}"

# ---------- 2. 创建 GitHub 协作同步回导脚本 ----------
IMPORT_SCRIPT="${SCRIPTS_DIR}/import-from-github.sh"
cat > "${IMPORT_SCRIPT}" << 'IMPEOF'
#!/bin/bash
set -euo pipefail

######################################################################
# import-from-github.sh
# 将 GitHub repo 的变更导回 Overleaf project
# （通过上传 zip 的方式，覆盖 project 内容）
#
# 用法: import-from-github.sh <project-id> <github-repo-local-path>
######################################################################

CONTAINER="sharelatex"
PROJECT_ID="${1:-}"
REPO_PATH="${2:-}"

if [[ -z "${PROJECT_ID}" || -z "${REPO_PATH}" ]]; then
  echo "用法: $0 <project-id> <repo-local-path>"
  echo "示例: $0 64a1b2c3d4e5f6 \${OVERLEAF_BASE_DIR}/github-repos/my-paper-64a1b2c3d4e5f6"
  exit 1
fi

if [[ ! -d "${REPO_PATH}" ]]; then
  echo "目录不存在: ${REPO_PATH}" >&2
  exit 1
fi

echo "警告: 此操作会用 GitHub repo 的内容覆盖 Overleaf project!"
echo "Project ID: ${PROJECT_ID}"
echo "Repo 路径: ${REPO_PATH}"
read -rp "确认继续？(y/N) " confirm
[[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && exit 0

TMP_ZIP="/tmp/import-${PROJECT_ID}.zip"

# 打包 repo（排除 .git）
echo "打包 repo 内容..."
cd "${REPO_PATH}"
zip -r "${TMP_ZIP}" . -x '.git/*' -x '.gitignore' -x 'README.md'

# 拷贝到容器内
docker cp "${TMP_ZIP}" "${CONTAINER}:/tmp/"

echo "导入到 Overleaf project..."
echo "注意: 社区版暂不支持 API 直接上传覆盖 project。"
echo "请手动执行以下步骤："
echo "  1. 在 Overleaf 界面打开该 project"
echo "  2. 点击菜单 → Upload Project → 上传 ${TMP_ZIP}"
echo "  或将文件逐个上传替换"
echo ""
echo "zip 文件已准备好: ${TMP_ZIP}"

rm -f "${TMP_ZIP}"
IMPEOF
chmod +x "${IMPORT_SCRIPT}"

# ---------- 3. 输出协作说明 ----------
log "===== 多人协作配置完成 ====="
log ""
log "用户管理工具: ${USER_MGMT}"
log "  创建用户:     ${USER_MGMT} create alice@example.com"
log "  创建管理员:   ${USER_MGMT} create admin@example.com --admin"
log "  批量创建:     ${USER_MGMT} batch-create users.txt"
log "  列出用户:     ${USER_MGMT} list"
log ""
log "协作工作流说明:"
log "  1. [在线协作] 多人通过浏览器访问同一个 Overleaf project 即可实时编辑"
log "  2. [GitHub 同步] 每 N 分钟自动将 Overleaf 变更同步到 GitHub repo"
log "  3. [离线编辑] 团队成员可 git clone GitHub repo，本地编辑后提交 PR"
log "  4. [回导变更] 使用 ${IMPORT_SCRIPT} 将 GitHub 变更导回 Overleaf"
