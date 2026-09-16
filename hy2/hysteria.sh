#!/usr/bin/env bash
# Hysteria 2 一键安装/配置脚本
# 特性：
# - Debian / Ubuntu / RHEL 系
# - 自动安装最新版 Hysteria 2
# - Let's Encrypt + acme.sh 自动申请证书
# - acme.sh 自动续期并自动部署证书
# - 支持单端口 / 原生 UDP 端口跳跃
# - Salamander 混淆
# - 随机密码 / 自定义密码
# - systemd 服务
# - 安装完成输出 hysteria2:// 分享链接
# - 支持 status / restart / logs / uninstall

set -Eeuo pipefail
export LANG=C.UTF-8

readonly HYSTERIA_DIR="/etc/hysteria"
readonly CONFIG_FILE="${HYSTERIA_DIR}/config.yaml"
readonly DOMAIN_FILE="${HYSTERIA_DIR}/domain"
readonly ACME_HOME="/root/.acme.sh"
readonly CERT_FILE="${HYSTERIA_DIR}/cert.crt"
readonly KEY_FILE="${HYSTERIA_DIR}/private.key"
readonly SHARE_FILE="${HYSTERIA_DIR}/share.txt"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[x]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "脚本执行失败，行号：${LINENO}，命令：${BASH_COMMAND}"' ERR

require_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        PM=apt
    elif command -v dnf >/dev/null 2>&1; then
        PM=dnf
    elif command -v yum >/dev/null 2>&1; then
        PM=yum
    else
        die "未找到 apt/dnf/yum，暂不支持当前系统。"
    fi
}

pkg_update() {
    case "$PM" in
        apt) apt-get update ;;
        dnf) dnf makecache ;;
        yum) yum makecache ;;
    esac
}

pkg_install() {
    case "$PM" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
    esac
}

install_deps() {
    detect_pm
    log "安装依赖..."
    pkg_update
    case "$PM" in
        apt)
            pkg_install curl wget openssl socat ca-certificates dnsutils qrencode iproute2
            ;;
        dnf|yum)
            pkg_install curl wget openssl socat ca-certificates bind-utils qrencode iproute
            ;;
    esac
}

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_available_udp() {
    local p="$1"
    ! ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$p$"
}

get_public_ipv4() {
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

dns_ipv4() {
    local d="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$d" | grep -E '^[0-9.]+$' | head -n1 || true
    else
        getent ahostsv4 "$d" | awk 'NR==1{print $1}'
    fi
}

check_domain() {
    local domain="$1"
    local dns_ip public_ip

    dns_ip="$(dns_ipv4 "$domain")"
    public_ip="$(get_public_ipv4)"

    [[ -n "$dns_ip" ]] || die "域名 $domain 没有解析到 IPv4。"
    log "域名 IPv4：$dns_ip"

    if [[ -n "$public_ip" ]]; then
        log "服务器 IPv4：$public_ip"
        if [[ "$dns_ip" != "$public_ip" ]]; then
            die "域名解析 IP 与服务器公网 IPv4 不一致。请先把 $domain 解析到 $public_ip。"
        fi
    else
        warn "无法获取服务器公网 IPv4，将跳过本机 IP 比对。"
    fi
}

install_hysteria() {
    if [[ -x /usr/local/bin/hysteria ]]; then
        log "检测到已安装 Hysteria：$(/usr/local/bin/hysteria version 2>/dev/null | head -n1 || true)"
        return
    fi

    log "安装 Hysteria 2 官方服务..."
    bash <(curl -fsSL https://get.hy2.sh)
    [[ -x /usr/local/bin/hysteria ]] || die "Hysteria 安装失败。"
}

install_acme() {
    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
        log "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}"
    fi

    [[ -x "${ACME_HOME}/acme.sh" ]] || die "acme.sh 安装失败。"

    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt
    "${ACME_HOME}/acme.sh" --upgrade --auto-upgrade || true
}

check_port80() {
    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)80$'; then
        warn "TCP 80 当前已被占用。"
        ss -ltnp | grep -E '(:80[[:space:]])|(:80$)' || true
        die "standalone ACME 需要 TCP 80 空闲。请先停止占用 80 端口的服务后重新运行。"
    fi
}

issue_certificate() {
    mkdir -p "$HYSTERIA_DIR"

    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" && -s "$DOMAIN_FILE" ]] \
        && [[ "$(cat "$DOMAIN_FILE")" == "$DOMAIN" ]]; then
        log "检测到已有 $DOMAIN 证书，尝试续期/重新部署..."
        "${ACME_HOME}/acme.sh" --renew -d "$DOMAIN" --ecc || true
    else
        check_port80
        log "申请 Let's Encrypt ECC 证书..."
        "${ACME_HOME}/acme.sh" \
            --issue \
            -d "$DOMAIN" \
            --standalone \
            --keylength ec-256
    fi

    "${ACME_HOME}/acme.sh" \
        --install-cert \
        -d "$DOMAIN" \
        --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "systemctl try-reload-or-restart hysteria-server.service >/dev/null 2>&1 || true"

    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "证书部署失败。"

    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
    printf '%s\n' "$DOMAIN" > "$DOMAIN_FILE"
}

configure_hysteria() {
    read -rp "Hysteria 2 监听端口 [30010]: " PORT
    PORT="${PORT:-30010}"
    valid_port "$PORT" || die "端口必须是 1-65535。"

    if ! port_available_udp "$PORT" && ! ss -H -lun 2>/dev/null | grep -Eq ":${PORT}[[:space:]]"; then
        die "UDP $PORT 已被占用。"
    fi

    read -rp "启用 UDP 端口跳跃？[y/N]: " ENABLE_HOP
    ENABLE_HOP="${ENABLE_HOP:-N}"

    HOP_RANGE=""
    if [[ "$ENABLE_HOP" =~ ^[Yy]$ ]]; then
        read -rp "端口跳跃范围 [30010-30100]: " HOP_RANGE
        HOP_RANGE="${HOP_RANGE:-30010-30100}"
        [[ "$HOP_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || die "端口范围格式错误，例如 30010-30100。"

        local first="${HOP_RANGE%-*}"
        local last="${HOP_RANGE#*-}"
        valid_port "$first" || die "跳跃起始端口无效。"
        valid_port "$last" || die "跳跃结束端口无效。"
        (( first < last )) || die "结束端口必须大于起始端口。"
    fi

    read -rp "Hysteria 2 密码（回车随机生成）: " AUTH_PASSWORD
    AUTH_PASSWORD="${AUTH_PASSWORD:-$(random_password)}"

    read -rp "Salamander 混淆密码（回车随机生成）: " OBFS_PASSWORD
    OBFS_PASSWORD="${OBFS_PASSWORD:-$(random_password)}"

    read -rp "伪装网站 [https://www.cloudflare.com/]: " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-https://www.cloudflare.com/}"

    if [[ ! "$MASQUERADE_URL" =~ ^https?:// ]]; then
        MASQUERADE_URL="https://${MASQUERADE_URL}"
    fi

    local listen=":${PORT}"
    if [[ -n "$HOP_RANGE" ]]; then
        listen=":${HOP_RANGE}"
    fi

    mkdir -p "$HYSTERIA_DIR"
    chmod 700 "$HYSTERIA_DIR"

    cat > "$CONFIG_FILE" <<EOF
listen: ${listen}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: ${AUTH_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    chmod 600 "$CONFIG_FILE"

    # 保存供管理命令使用的非敏感/必要参数
    cat > "${HYSTERIA_DIR}/env" <<EOF
DOMAIN='${DOMAIN}'
PORT='${PORT}'
HOP_RANGE='${HOP_RANGE}'
EOF
    chmod 600 "${HYSTERIA_DIR}/env"

    # 让 systemd 在配置出错时直接给出明确错误
    /usr/local/bin/hysteria server --config "$CONFIG_FILE" check
}

start_service() {
    systemctl daemon-reload
    systemctl enable hysteria-server.service >/dev/null
    systemctl restart hysteria-server.service
    sleep 1

    if ! systemctl is-active --quiet hysteria-server.service; then
        systemctl --no-pager -l status hysteria-server.service || true
        die "Hysteria 2 启动失败，请执行：journalctl -u hysteria-server -n 100 --no-pager"
    fi

    log "Hysteria 2 服务运行正常。"
}

generate_share_link() {
    local host="$DOMAIN"
    local port="$PORT"
    local uri_port="$port"

    if [[ -n "${HOP_RANGE:-}" ]]; then
        uri_port="${HOP_RANGE}"
    fi

    SHARE_LINK="hysteria2://${AUTH_PASSWORD}@${host}:${uri_port}?sni=${host}&obfs=salamander&obfs-password=${OBFS_PASSWORD}#HY2"

    printf '%s\n' "$SHARE_LINK" > "$SHARE_FILE"
    chmod 600 "$SHARE_FILE"
}

show_info() {
    [[ -s "$SHARE_FILE" ]] || die "尚未安装 Hysteria 2。"

    echo
    echo -e "${GREEN}========== Hysteria 2 信息 ==========${RESET}"
    echo "域名      : ${DOMAIN}"
    echo "端口      : ${PORT}"
    [[ -n "${HOP_RANGE:-}" ]] && echo "端口跳跃  : ${HOP_RANGE}"
    echo "证书      : ${CERT_FILE}"
    echo "配置      : ${CONFIG_FILE}"
    echo "服务      : hysteria-server.service"
    echo
    echo "分享链接："
    cat "$SHARE_FILE"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        echo "二维码："
        qrencode -t ANSIUTF8 < "$SHARE_FILE" || true
    fi
    echo
}

install() {
    require_root
    detect_pm
    install_deps
    install_hysteria

    read -rp "请输入证书域名: " DOMAIN
    DOMAIN="${DOMAIN:-}"
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名格式无效。"

    check_domain "$DOMAIN"
    install_acme
    issue_certificate
    configure_hysteria
    start_service
    generate_share_link
    show_info

    log "安装完成。"
    echo "管理命令："
    echo "  $0 status"
    echo "  $0 restart"
    echo "  $0 logs"
    echo "  $0 info"
    echo "  $0 uninstall"
}

status_cmd() {
    systemctl --no-pager -l status hysteria-server.service
}

restart_cmd() {
    systemctl restart hysteria-server.service
    systemctl is-active --quiet hysteria-server.service && log "重启成功。"
}

logs_cmd() {
    journalctl -u hysteria-server.service -n 100 --no-pager
}

info_cmd() {
    [[ -s "$DOMAIN_FILE" ]] || die "未检测到安装信息。"
    DOMAIN="$(cat "$DOMAIN_FILE")"
    [[ -f "${HYSTERIA_DIR}/env" ]] && source "${HYSTERIA_DIR}/env"
    show_info
}

uninstall_cmd() {
    require_root
    warn "此操作将删除 Hysteria 2、配置、证书及 acme.sh 对应证书。"
    read -rp "输入 YES 确认卸载: " confirm
    [[ "$confirm" == "YES" ]] || { log "已取消。"; exit 0; }

    systemctl disable --now hysteria-server.service 2>/dev/null || true

    if [[ -x /usr/local/bin/hysteria ]]; then
        /usr/local/bin/hysteria server uninstall 2>/dev/null || true
    fi

    if [[ -x "${ACME_HOME}/acme.sh" && -s "$DOMAIN_FILE" ]]; then
        local d
        d="$(cat "$DOMAIN_FILE")"
        "${ACME_HOME}/acme.sh" --remove -d "$d" --ecc 2>/dev/null || true
    fi

    rm -rf "$HYSTERIA_DIR"
    rm -f /usr/local/bin/hysteria
    rm -f /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload

    log "Hysteria 2 已卸载。"
}

usage() {
    cat <<EOF
Hysteria 2 管理脚本

用法：
  $0                 安装/重新配置
  $0 install         安装/重新配置
  $0 status          查看服务状态
  $0 restart         重启服务
  $0 logs            查看最近日志
  $0 info            查看节点信息
  $0 uninstall       卸载
EOF
}

main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install)   install ;;
        status)    status_cmd ;;
        restart)   restart_cmd ;;
        logs)      logs_cmd ;;
        info)      info_cmd ;;
        uninstall) uninstall_cmd ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
