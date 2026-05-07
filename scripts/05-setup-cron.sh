#!/bin/bash
set -euo pipefail

######################################################################
# 05-setup-cron.sh
# 配置定时同步 cron 任务 + systemd 服务（可选）
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

SYNC_SCRIPT="${SCRIPTS_DIR}/overleaf-github-sync.sh"

log "===== 配置定时同步任务 ====="

# ---------- 1. 确认同步脚本存在 ----------
if [[ ! -x "${SYNC_SCRIPT}" ]]; then
  log "错误: 同步脚本不存在或不可执行: ${SYNC_SCRIPT}"
  exit 1
fi

# ---------- 2. 创建 cron wrapper ----------
CRON_WRAPPER="${SCRIPTS_DIR}/cron-sync-wrapper.sh"
cat > "${CRON_WRAPPER}" << WRAPEOF
#!/bin/bash
# cron 环境下的同步 wrapper，确保环境变量和日志正确
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export OVERLEAF_BASE_DIR="${OVERLEAF_BASE_DIR}"

LOGFILE="${LOGS_DIR}/github-sync.log"
MAX_LOG_SIZE=10485760  # 10MB

# 日志轮转
if [[ -f "\${LOGFILE}" ]] && [[ \$(stat -c%s "\${LOGFILE}" 2>/dev/null || echo 0) -gt \${MAX_LOG_SIZE} ]]; then
  mv "\${LOGFILE}" "\${LOGFILE}.old"
fi

echo "========== \$(date '+%Y-%m-%d %H:%M:%S') cron 同步开始 ==========" >> "\${LOGFILE}"
"${SYNC_SCRIPT}" >> "\${LOGFILE}" 2>&1
echo "========== \$(date '+%Y-%m-%d %H:%M:%S') cron 同步结束 ==========" >> "\${LOGFILE}"
WRAPEOF
chmod +x "${CRON_WRAPPER}"

# ---------- 3. 安装 cron 任务（安全方式：备份原有 crontab 再追加）----------
CRON_LINE="*/${SYNC_INTERVAL} * * * * ${CRON_WRAPPER}"

# 备份当前 crontab
CRON_BACKUP="${LOGS_DIR}/crontab-backup-$(date +%Y%m%d%H%M%S).txt"
crontab -l > "${CRON_BACKUP}" 2>/dev/null || true
log "已备份现有 crontab 到: ${CRON_BACKUP}"

# 安全追加：仅移除本项目的旧条目（精确匹配路径），保留其他所有条目
EXISTING=$(crontab -l 2>/dev/null || true)
NEW_CRONTAB=$(echo "${EXISTING}" | grep -vF "${CRON_WRAPPER}" || true)
echo "${NEW_CRONTAB}
${CRON_LINE}" | crontab -

log "Cron 任务已安装：每 ${SYNC_INTERVAL} 分钟执行一次"
log "日志文件: ${LOGS_DIR}/github-sync.log"

# ---------- 4. 创建手动触发脚本 ----------
MANUAL_SYNC="${SCRIPTS_DIR}/manual-sync.sh"
cat > "${MANUAL_SYNC}" << MSEOF
#!/bin/bash
# 手动触发一次完整同步
echo "手动触发 Overleaf → GitHub 同步..."
export OVERLEAF_BASE_DIR="${OVERLEAF_BASE_DIR}"
exec "${SYNC_SCRIPT}" "\$@"
MSEOF
chmod +x "${MANUAL_SYNC}"

log "手动同步脚本: ${MANUAL_SYNC}"
log "  用法: ${MANUAL_SYNC}                    # 同步所有项目"
log "  用法: ${MANUAL_SYNC} --dry-run           # 仅预览，不推送"
log "  用法: ${MANUAL_SYNC} --project-id <id>   # 同步指定项目"

log "===== 定时同步任务配置完成 ====="
