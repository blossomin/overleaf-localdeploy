#!/bin/bash
set -euo pipefail

######################################################################
# overleaf-github-sync.sh
# 核心同步脚本：将 Overleaf 每个 project 同步到独立的 GitHub repo
#
# 工作流程:
#   1. 通过 MongoDB 查询所有 projects (id + name)
#   2. 逐个 project 通过容器内脚本导出 zip
#   3. 解压到对应的本地 git repo
#   4. 检测变更，git commit + push 到 GitHub
#
# 用法:
#   overleaf-github-sync.sh [--dry-run] [--project-id <id>]
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SYNC] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# ---- 配置 ----
MAPPING_FILE="${SYNC_DIR}/project-repo-mapping.json"
TMP_DIR="${SYNC_DIR}/tmp"
LOCK_FILE="${SYNC_DIR}/.sync.lock"

# 使用项目级 gitconfig，不影响全局 git 配置
export GIT_CONFIG_GLOBAL="${SYNC_DIR}/.gitconfig"

DRY_RUN=false
SINGLE_PROJECT_ID=""

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --project-id) SINGLE_PROJECT_ID="$2"; shift 2 ;;
    *) err "未知参数: $1" ;;
  esac
done

# ---- 读取配置 ----
if [[ ! -f "${MAPPING_FILE}" ]]; then
  err "映射配置文件不存在: ${MAPPING_FILE}"
fi
GITHUB_USER=$(jq -r '.github_user' "${MAPPING_FILE}")
GITHUB_TOKEN_FILE=$(jq -r '.github_token_file' "${MAPPING_FILE}")
DEFAULT_VISIBILITY=$(jq -r '.default_visibility' "${MAPPING_FILE}")
REPO_PREFIX=$(jq -r '.repo_prefix' "${MAPPING_FILE}")

if [[ -f "${GITHUB_TOKEN_FILE}" ]]; then
  GITHUB_TOKEN=$(grep 'github.com' "${GITHUB_TOKEN_FILE}" | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
else
  err "GitHub Token 文件不存在: ${GITHUB_TOKEN_FILE}"
fi

# ---- 锁机制（防止并发执行）----
acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local lock_pid
    lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
    if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
      err "同步正在运行中 (PID: ${lock_pid})，退出"
    else
      warn "发现过期锁文件，清理..."
      rm -f "${LOCK_FILE}"
    fi
  fi
  echo $$ > "${LOCK_FILE}"
}

release_lock() {
  rm -f "${LOCK_FILE}"
}
trap release_lock EXIT

# ---- 辅助函数：安全化项目名（用于目录和 repo 名）----
sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# ---- 辅助函数：通过 GitHub API 创建 repo ----
create_github_repo() {
  local repo_name="$1"
  local visibility="$2"
  local private_flag="true"
  [[ "${visibility}" == "public" ]] && private_flag="false"

  log "在 GitHub 创建仓库: ${GITHUB_USER}/${repo_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] 跳过创建 GitHub 仓库"
    return 0
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/user/repos" \
    -d "{\"name\":\"${repo_name}\",\"private\":${private_flag},\"auto_init\":false}")

  if [[ "${http_code}" == "201" ]]; then
    log "GitHub 仓库创建成功: ${repo_name}"
    return 0
  elif [[ "${http_code}" == "422" ]]; then
    log "GitHub 仓库已存在: ${repo_name}"
    return 0
  else
    warn "GitHub 仓库创建失败 (HTTP ${http_code}): ${repo_name}"
    return 1
  fi
}

# ---- 辅助函数：导出单个 project 为 zip ----
export_project_zip() {
  local project_id="$1"
  local output_zip="$2"

  log "导出 project: ${project_id} -> ${output_zip}"

  # 使用 docker exec 在 sharelatex 容器内运行导出脚本
  docker exec sharelatex bash -c "
    cd /overleaf/services/web && \
    node modules/server-ce-scripts/scripts/export-user-projects.mjs \
      --project-id '${project_id}' \
      --output '/tmp/export-${project_id}.zip' \
      --log-level error
  " || {
    warn "导出失败 (project: ${project_id}), 尝试备选方案..."
    # 备选方案：直接从数据目录打包
    return 1
  }

  # 从容器中拷贝 zip 文件
  docker cp "sharelatex:/tmp/export-${project_id}.zip" "${output_zip}" || return 1
  # 清理容器内临时文件
  docker exec sharelatex rm -f "/tmp/export-${project_id}.zip" 2>/dev/null || true

  return 0
}

# ---- 辅助函数：同步单个 project ----
sync_one_project() {
  local project_id="$1"
  local project_name="$2"

  local safe_name
  safe_name=$(sanitize_name "${project_name}")
  local repo_name="${REPO_PREFIX}${safe_name}"
  local repo_dir="${REPOS_DIR}/${safe_name}-${project_id}"
  local zip_file="${TMP_DIR}/${project_id}.zip"

  log "--- 同步 project: ${project_name} (${project_id}) ---"

  # 1. 导出 zip
  mkdir -p "${TMP_DIR}"
  if ! export_project_zip "${project_id}" "${zip_file}"; then
    warn "跳过 project ${project_name} (导出失败)"
    return 1
  fi

  if [[ ! -f "${zip_file}" ]]; then
    warn "跳过 project ${project_name} (zip 文件不存在)"
    return 1
  fi

  # 2. 确保本地 git repo 存在
  if [[ ! -d "${repo_dir}/.git" ]]; then
    log "初始化本地 git 仓库: ${repo_dir}"
    # 在 GitHub 创建远程 repo
    create_github_repo "${repo_name}" "${DEFAULT_VISIBILITY}" || true

    mkdir -p "${repo_dir}"
    cd "${repo_dir}"
    git init
    git remote add origin "https://github.com/${GITHUB_USER}/${repo_name}.git" 2>/dev/null || true

    # 创建初始 README
    echo "# ${project_name}" > README.md
    echo "" >> README.md
    echo "Overleaf project synced automatically." >> README.md
    echo "Project ID: \`${project_id}\`" >> README.md
    git add README.md
    git commit -m "Initial commit: ${project_name}" --allow-empty

    if [[ "${DRY_RUN}" != "true" ]]; then
      git push -u origin main 2>/dev/null || git push -u origin main --force 2>/dev/null || true
    fi
  fi

  cd "${repo_dir}"

  # 3. 解压 zip 覆盖 repo（保留 .git 和 README.md）
  local extract_dir="${TMP_DIR}/extract-${project_id}"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  unzip -o -q "${zip_file}" -d "${extract_dir}" 2>/dev/null || {
    warn "解压失败: ${zip_file}"
    rm -f "${zip_file}"
    return 1
  }

  # 找到解压后的实际内容目录（可能有一层嵌套）
  local content_dir="${extract_dir}"
  local subdirs
  subdirs=$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d)
  if [[ $(echo "${subdirs}" | wc -l) -eq 1 ]] && [[ -n "${subdirs}" ]]; then
    content_dir="${subdirs}"
  fi

  # 清理旧文件（保留 .git 和 README.md）
  find "${repo_dir}" -mindepth 1 -maxdepth 1 \
    ! -name '.git' ! -name 'README.md' ! -name '.gitignore' \
    -exec rm -rf {} + 2>/dev/null || true

  # 拷贝新文件
  cp -a "${content_dir}"/. "${repo_dir}/" 2>/dev/null || true

  # 创建 .gitignore
  if [[ ! -f "${repo_dir}/.gitignore" ]]; then
    cat > "${repo_dir}/.gitignore" << 'GIEOF'
# Overleaf 编译产物
*.aux
*.log
*.out
*.toc
*.bbl
*.blg
*.fls
*.fdb_latexmk
*.synctex.gz
*.synctex(busy)
GIEOF
  fi

  # 4. 检测变更并提交
  git add -A
  if git diff --cached --quiet; then
    log "无变更，跳过: ${project_name}"
  else
    local commit_msg="Sync from Overleaf: $(date '+%Y-%m-%d %H:%M:%S')"
    git commit -m "${commit_msg}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      log "[DRY-RUN] 跳过 push: ${project_name}"
    else
      git push origin main 2>&1 || warn "Push 失败: ${repo_name}"
      log "已同步: ${project_name} -> ${GITHUB_USER}/${repo_name}"
    fi
  fi

  # 5. 更新映射文件
  local tmp_map="${MAPPING_FILE}.tmp"
  jq --arg pid "${project_id}" \
     --arg pname "${project_name}" \
     --arg rname "${repo_name}" \
     --arg rdir "${repo_dir}" \
     '.projects[$pid] = {"name": $pname, "repo": $rname, "local_path": $rdir, "last_sync": now | todate}' \
     "${MAPPING_FILE}" > "${tmp_map}" && mv "${tmp_map}" "${MAPPING_FILE}"

  # 清理临时文件
  rm -f "${zip_file}"
  rm -rf "${extract_dir}"

  log "--- 完成: ${project_name} ---"
  return 0
}

# ======== 主流程 ========
main() {
  acquire_lock
  log "===== Overleaf → GitHub 同步开始 ====="
  [[ "${DRY_RUN}" == "true" ]] && log "*** DRY-RUN 模式 ***"

  mkdir -p "${TMP_DIR}"

  # 从 MongoDB 查询所有 projects
  log "查询 Overleaf 项目列表..."

  local projects_json
  if [[ -n "${SINGLE_PROJECT_ID}" ]]; then
    # 同步单个项目
    projects_json=$(docker exec mongo mongosh --quiet "mongodb://localhost/sharelatex" --eval "
      const p = db.projects.findOne({_id: ObjectId('${SINGLE_PROJECT_ID}')}, {name: 1});
      if (p) printjson([{id: p._id.toString(), name: p.name}]);
      else printjson([]);
    " 2>/dev/null || echo "[]")
  else
    # 同步所有项目
    projects_json=$(docker exec mongo mongosh --quiet "mongodb://localhost/sharelatex" --eval "
      const projects = db.projects.find({}, {name: 1}).toArray();
      printjson(projects.map(p => ({id: p._id.toString(), name: p.name})));
    " 2>/dev/null || echo "[]")
  fi

  # 解析 JSON，兼容不同 mongosh 输出格式
  projects_json=$(echo "${projects_json}" | grep -v "^$" | tail -1)

  local count
  count=$(echo "${projects_json}" | jq 'length' 2>/dev/null || echo "0")
  log "找到 ${count} 个项目"

  if [[ "${count}" -eq 0 ]]; then
    log "没有需要同步的项目"
    return 0
  fi

  local success=0
  local failed=0

  for i in $(seq 0 $((count - 1))); do
    local pid pname
    pid=$(echo "${projects_json}" | jq -r ".[$i].id")
    pname=$(echo "${projects_json}" | jq -r ".[$i].name")

    if sync_one_project "${pid}" "${pname}"; then
      ((success++))
    else
      ((failed++))
    fi
  done

  # 清理临时目录
  rm -rf "${TMP_DIR}"

  log "===== 同步完成: 成功 ${success}, 失败 ${failed}, 共 ${count} ====="
}

main "$@"
