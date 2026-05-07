#!/bin/bash
set -euo pipefail

######################################################################
# 03-setup-tls.sh
# 配置 TLS 证书：支持自签名 / Let's Encrypt 两种模式
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

CERT_DIR="${TOOLKIT_DIR}/config/nginx/certs"
CERT_FILE="${CERT_DIR}/overleaf_certificate.pem"
KEY_FILE="${CERT_DIR}/overleaf_key.pem"

CN="${DOMAIN:-${PUBLIC_IP}}"
if [[ -z "${CN}" ]]; then
  err "请设置 DOMAIN 或 PUBLIC_IP 环境变量"
fi

log "===== TLS 证书配置 (模式: ${TLS_MODE}) ====="

mkdir -p "${CERT_DIR}"

case "${TLS_MODE}" in
  # ========== 自签名证书 ==========
  self-signed)
    log "生成自签名证书 (CN=${CN})..."

    # 生成带 SAN 的自签名证书，有效期 10 年
    openssl req -x509 -nodes -days 3650 \
      -newkey rsa:2048 \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}" \
      -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Overleaf/CN=${CN}" \
      -addext "subjectAltName=DNS:${CN},IP:${PUBLIC_IP:-127.0.0.1}"

    log "自签名证书已生成："
    log "  证书: ${CERT_FILE}"
    log "  私钥: ${KEY_FILE}"
    log ""
    log "注意：浏览器会显示安全警告，这是正常现象。"
    log "你可以在客户端手动信任此证书以消除警告。"
    ;;

  # ========== Let's Encrypt ==========
  letsencrypt)
    if [[ -z "${DOMAIN}" ]]; then
      err "Let's Encrypt 模式需要设置 DOMAIN 环境变量（不能使用纯 IP）"
    fi

    log "使用 Let's Encrypt 申请证书 (域名: ${DOMAIN})..."

    # 安装 certbot
    if ! command -v certbot &>/dev/null; then
      log "安装 certbot..."
      apt-get update -qq
      apt-get install -y -qq certbot
    fi

    # 先停止 NGINX（如果正在运行），释放 80 端口
    cd "${TOOLKIT_DIR}"
    bin/docker-compose stop nginx 2>/dev/null || true

    # 申请证书（standalone 模式，需要 80 端口可用）
    certbot certonly --standalone \
      --non-interactive \
      --agree-tos \
      --email "${ADMIN_EMAIL}" \
      -d "${DOMAIN}"

    # 拷贝证书到 toolkit 的配置目录
    LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"
    cp "${LETSENCRYPT_DIR}/fullchain.pem" "${CERT_FILE}"
    cp "${LETSENCRYPT_DIR}/privkey.pem" "${KEY_FILE}"

    log "Let's Encrypt 证书已申请并拷贝到 toolkit 配置目录"

    # 配置自动续期 cron
    RENEW_SCRIPT="${OVERLEAF_BASE_DIR}/scripts/renew-cert.sh"
    cat > "${RENEW_SCRIPT}" << 'RENEWEOF'
#!/bin/bash
set -euo pipefail
TOOLKIT_DIR="__TOOLKIT_DIR__"
DOMAIN="__DOMAIN__"
CERT_DIR="${TOOLKIT_DIR}/config/nginx/certs"

# 续期
certbot renew --quiet

# 拷贝新证书
cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DIR}/overleaf_certificate.pem"
cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"    "${CERT_DIR}/overleaf_key.pem"

# 重载 NGINX
cd "${TOOLKIT_DIR}" && bin/docker-compose exec nginx nginx -s reload
RENEWEOF

    sed -i "s|__TOOLKIT_DIR__|${TOOLKIT_DIR}|g" "${RENEW_SCRIPT}"
    sed -i "s|__DOMAIN__|${DOMAIN}|g" "${RENEW_SCRIPT}"
    chmod +x "${RENEW_SCRIPT}"

    # 添加 cron：每天凌晨 3 点检查续期
    CRON_LINE="0 3 * * * ${RENEW_SCRIPT} >> ${OVERLEAF_BASE_DIR}/logs/cert-renew.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "renew-cert.sh"; echo "${CRON_LINE}") | crontab -

    log "已配置证书自动续期 cron (每天 03:00)"
    ;;

  *)
    err "不支持的 TLS_MODE: ${TLS_MODE}，可选: self-signed, letsencrypt"
    ;;
esac

log "===== TLS 证书配置完成 ====="
