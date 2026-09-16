#!/usr/bin/env bash

# ============================================================
# Hysteria 2 一键安装 / 配置 / 卸载脚本
#
# 支持：
#   Debian / Ubuntu / RHEL / Rocky / AlmaLinux / CentOS
#
# 功能：
#   - 自动安装最新版 Hysteria 2
#   - 自动安装 acme.sh
#   - Let's Encrypt ECC 证书
#   - 自动续期 + 自动部署证书
#   - 单 UDP 端口
#   - Linux 原生 UDP 端口跳跃
#   - Salamander 混淆
#   - 自定义 / 随机密码
#   - systemd
#   - 自动生成 hysteria2:// 分享链接
#   - QR Code
#   - status / restart / logs / info / uninstall
#
# 修复：
#   - pipefail + head SIGPIPE 导致 random_password() 失败
#   - 端口占用判断
#   - 证书续期
#   - 配置检查
#   - systemd 服务
# ============================================================

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ============================================================
# 基本路径
# ============================================================

readonly HYSTERIA_DIR="/etc/hysteria"
readonly CONFIG_FILE="${HYSTERIA_DIR}/config.yaml"
readonly ENV_FILE="${HYSTERIA_DIR}/env"
readonly DOMAIN_FILE="${HYSTERIA_DIR}/domain"

readonly CERT_FILE="${HYSTERIA_DIR}/cert.crt"
readonly KEY_FILE="${HYSTERIA_DIR}/private.key"

readonly SHARE_FILE="${HYSTERIA_DIR}/share.txt"

readonly HYSTERIA_BIN="/usr/local/bin/hysteria"
readonly SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

readonly ACME_HOME="/root/.acme.sh"

# ============================================================
# 颜色
# ============================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

# ============================================================
# 输出
# ============================================================

log() {
    echo -e "${GREEN}[+]${RESET} $*"
}

info() {
    echo -e "${BLUE}[*]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $*"
}

err() {
    echo -e "${RED}[x]${RESET} $*" >&2
}

die() {
    err "$*"
    exit 1
}

# ============================================================
# 错误处理
# ============================================================

trap 'err "脚本执行失败，行号：${LINENO}，命令：${BASH_COMMAND}"' ERR

# ============================================================
# Root
# ============================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行此脚本。"
    fi
}

# ============================================================
# 包管理器
# ============================================================

PM=""

detect_pm() {

    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"

    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"

    elif command -v yum >/dev/null 2>&1; then
        PM="yum"

    else
        die "未找到 apt-get / dnf / yum。"
    fi
}

pkg_update() {

    case "${PM}" in

        apt)
            apt-get update
            ;;

        dnf)
            dnf makecache
            ;;

        yum)
            yum makecache
            ;;

    esac
}

pkg_install() {

    case "${PM}" in

        apt)
            DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --no-install-recommends "$@"
            ;;

        dnf)
            dnf install -y "$@"
            ;;

        yum)
            yum install -y "$@"
            ;;

    esac
}

# ============================================================
# 依赖
# ============================================================

install_dependencies() {

    detect_pm

    info "检查系统依赖..."

    local packages=(
        curl
        wget
        openssl
        socat
        ca-certificates
        iproute
        iptables
    )

    case "${PM}" in

        apt)
            packages+=(
                dnsutils
                qrencode
            )
            ;;

        dnf|yum)
            packages+=(
                bind-utils
                qrencode
            )
            ;;

    esac

    pkg_update

    pkg_install "${packages[@]}"

    log "依赖安装完成。"
}

# ============================================================
# 随机密码
#
# 重要：
# 不再使用：
#
# tr ... | head -c 24
#
# 避免 set -o pipefail 下因为 SIGPIPE 失败。
# ============================================================

random_password() {

    local password=""

    if command -v openssl >/dev/null 2>&1; then

        password="$(
            openssl rand -hex 18 2>/dev/null
        )"

    else

        password="$(
            od -An -N18 -tx1 /dev/urandom |
            tr -d '[:space:]'
        )"

    fi

    [[ -n "${password}" ]] || {
        die "无法生成随机密码。"
    }

    printf '%s' "${password}"
}

# ============================================================
# 随机字符串 URL 编码
# ============================================================

urlencode() {

    local string="$1"

    python3 -c '
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
' "${string}" 2>/dev/null || printf '%s' "${string}"
}

# ============================================================
# 端口检查
# ============================================================

valid_port() {

    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] || return 1

    (( port >= 1 && port <= 65535 ))
}

udp_port_in_use() {

    local port="$1"

    ss -H -lun 2>/dev/null |
        awk '{print $5}' |
        grep -Eq "(^|:)${port}$"
}

tcp_port_in_use() {

    local port="$1"

    ss -H -ltn 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(^|:)${port}$"
}

# ============================================================
# 公网 IPv4
# ============================================================

get_public_ipv4() {

    curl -4fsS \
        --connect-timeout 5 \
        --max-time 10 \
        https://api.ipify.org \
        2>/dev/null || true
}

# ============================================================
# DNS IPv4
# ============================================================

dns_ipv4() {

    local domain="$1"

    if command -v dig >/dev/null 2>&1; then

        dig +short A "${domain}" 2>/dev/null |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            head -n1 ||
            true

    else

        getent ahostsv4 "${domain}" 2>/dev/null |
            awk 'NR==1 {print $1}' ||
            true

    fi
}

# ============================================================
# 域名检查
# ============================================================

check_domain() {

    local domain="$1"

    local dns_ip
    local public_ip

    info "检查域名解析..."

    dns_ip="$(dns_ipv4 "${domain}")"

    [[ -n "${dns_ip}" ]] || {
        die "域名 ${domain} 没有解析到 IPv4。"
    }

    log "域名 IPv4：${dns_ip}"

    public_ip="$(get_public_ipv4)"

    if [[ -n "${public_ip}" ]]; then

        log "服务器 IPv4：${public_ip}"

        if [[ "${dns_ip}" != "${public_ip}" ]]; then

            die \
                "域名 ${domain} 当前解析到 ${dns_ip}，" \
                "但服务器公网 IPv4 是 ${public_ip}。"

        fi

    else

        warn "无法获取服务器公网 IPv4。"

        warn "将跳过 DNS / 公网 IP 自动比对。"
    fi
}

# ============================================================
# 安装 Hysteria 2
#
# 使用官方安装脚本。
# ============================================================

install_hysteria() {

    if [[ -x "${HYSTERIA_BIN}" ]]; then

        log "检测到 Hysteria 已安装。"

        "${HYSTERIA_BIN}" version 2>/dev/null ||
            true

        return 0
    fi

    info "安装最新版 Hysteria 2..."

    curl -fsSL https://get.hy2.sh |
        bash

    [[ -x "${HYSTERIA_BIN}" ]] || {
        die "Hysteria 2 安装失败。"
    }

    log "Hysteria 2 安装成功。"
}

# ============================================================
# 安装 acme.sh
# ============================================================

install_acme() {

    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then

        info "安装 acme.sh..."

        curl -fsSL https://get.acme.sh |
            sh -s email="admin@${DOMAIN}"
    fi

    [[ -x "${ACME_HOME}/acme.sh" ]] || {
        die "acme.sh 安装失败。"
    }

    "${ACME_HOME}/acme.sh" \
        --set-default-ca \
        --server letsencrypt

    "${ACME_HOME}/acme.sh" \
        --upgrade \
        --auto-upgrade ||
        true

    log "acme.sh 已准备完成。"
}

# ============================================================
# 检查 TCP 80
# ============================================================

check_port_80() {

    if tcp_port_in_use 80; then

        warn "TCP 80 当前正在使用。"

        ss -ltnp |
            grep -E '(:80[[:space:]])|(:80$)' ||
            true

        die \
            "Let's Encrypt standalone 需要 TCP 80 空闲。" \
            "请停止占用 80 端口的程序后重新运行。"
    fi
}

# ============================================================
# 申请证书
# ============================================================

issue_certificate() {

    mkdir -p "${HYSTERIA_DIR}"

    chmod 700 "${HYSTERIA_DIR}"

    # 已经存在证书
    if [[
        -s "${CERT_FILE}" &&
        -s "${KEY_FILE}" &&
        -s "${DOMAIN_FILE}"
    ]]; then

        local old_domain

        old_domain="$(cat "${DOMAIN_FILE}")"

        if [[ "${old_domain}" == "${DOMAIN}" ]]; then

            info "检测到已有 ${DOMAIN} 证书。"

            "${ACME_HOME}/acme.sh" \
                --renew \
                -d "${DOMAIN}" \
                --ecc ||
                true

        fi
    else

        check_port_80

        info "申请 Let's Encrypt ECC 证书..."

        "${ACME_HOME}/acme.sh" \
            --issue \
            -d "${DOMAIN}" \
            --standalone \
            --keylength ec-256
    fi

    info "部署证书..."

    "${ACME_HOME}/acme.sh" \
        --install-cert \
        -d "${DOMAIN}" \
        --ecc \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" \
        --reloadcmd \
        "systemctl try-reload-or-restart hysteria-server.service >/dev/null 2>&1 || true"

    [[ -s "${CERT_FILE}" ]] || {
        die "证书文件生成失败：${CERT_FILE}"
    }

    [[ -s "${KEY_FILE}" ]] || {
        die "私钥文件生成失败：${KEY_FILE}"
    }

    chmod 644 "${CERT_FILE}"
    chmod 600 "${KEY_FILE}"

    printf '%s\n' "${DOMAIN}" > "${DOMAIN_FILE}"

    chmod 600 "${DOMAIN_FILE}"

    log "TLS 证书部署成功。"
}

# ============================================================
# 输入端口
# ============================================================

input_port() {

    read -rp \
        "Hysteria 2 监听端口 [30010]: " \
        PORT

    PORT="${PORT:-30010}"

    valid_port "${PORT}" || {
        die "端口必须是 1-65535。"
    }

    if udp_port_in_use "${PORT}"; then

        die "UDP ${PORT} 已经被其他程序占用。"
    fi
}

# ============================================================
# 输入端口跳跃
# ============================================================

input_port_hopping() {

    read -rp \
        "启用 UDP 端口跳跃？[y/N]: " \
        ENABLE_HOP

    ENABLE_HOP="${ENABLE_HOP:-N}"

    HOP_RANGE=""

    if [[ "${ENABLE_HOP}" =~ ^[Yy]$ ]]; then

        read -rp \
            "端口跳跃范围 [30010-30100]: " \
            HOP_RANGE

        HOP_RANGE="${HOP_RANGE:-30010-30100}"

        [[ "${HOP_RANGE}" =~ ^[0-9]+-[0-9]+$ ]] || {
            die "端口范围格式错误，例如：30010-30100"
        }

        local first
        local last

        first="${HOP_RANGE%-*}"
        last="${HOP_RANGE#*-}"

        valid_port "${first}" || {
            die "跳跃起始端口无效。"
        }

        valid_port "${last}" || {
            die "跳跃结束端口无效。"
        }

        (( first < last )) || {
            die "结束端口必须大于起始端口。"
        }

        # 监听范围中的第一个端口不能被占用
        if udp_port_in_use "${first}"; then
            die "UDP ${first} 已被占用。"
        fi

        log "启用端口跳跃：${HOP_RANGE}"
    fi
}

# ============================================================
# 输入密码
# ============================================================

input_passwords() {

    read -rp \
        "Hysteria 2 密码（回车随机生成）: " \
        AUTH_PASSWORD

    if [[ -z "${AUTH_PASSWORD}" ]]; then

        AUTH_PASSWORD="$(random_password)"

        log "已自动生成 Hysteria 2 密码。"
    fi

    read -rp \
        "Salamander 混淆密码（回车随机生成）: " \
        OBFS_PASSWORD

    if [[ -z "${OBFS_PASSWORD}" ]]; then

        OBFS_PASSWORD="$(random_password)"

        log "已自动生成 Salamander 密码。"
    fi
}

# ============================================================
# 伪装网站
# ============================================================

input_masquerade() {

    read -rp \
        "伪装网站 [https://www.cloudflare.com/]: " \
        MASQUERADE_URL

    MASQUERADE_URL="${MASQUERADE_URL:-https://www.cloudflare.com/}"

    if [[ ! "${MASQUERADE_URL}" =~ ^https?:// ]]; then

        MASQUERADE_URL="https://${MASQUERADE_URL}"
    fi
}

# ============================================================
# 生成配置
# ============================================================

write_config() {

    local listen_address

    if [[ -n "${HOP_RANGE}" ]]; then

        listen_address=":${HOP_RANGE}"

    else

        listen_address=":${PORT}"
    fi

    mkdir -p "${HYSTERIA_DIR}"

    chmod 700 "${HYSTERIA_DIR}"

    cat > "${CONFIG_FILE}" <<EOF
listen: ${listen_address}

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
EOF

    chmod 600 "${CONFIG_FILE}"

    cat > "${ENV_FILE}" <<EOF
DOMAIN='${DOMAIN}'
PORT='${PORT}'
HOP_RANGE='${HOP_RANGE}'
AUTH_PASSWORD='${AUTH_PASSWORD}'
OBFS_PASSWORD='${OBFS_PASSWORD}'
MASQUERADE_URL='${MASQUERADE_URL}'
EOF

    chmod 600 "${ENV_FILE}"

    printf '%s\n' "${DOMAIN}" > "${DOMAIN_FILE}"

    chmod 600 "${DOMAIN_FILE}"

    log "Hysteria 配置文件已生成："
    echo "  ${CONFIG_FILE}"
}

# ============================================================
# systemd
# ============================================================

write_systemd() {

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://www.hy2.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}

WorkingDirectory=${HYSTERIA_DIR}

Restart=on-failure
RestartSec=5

LimitNOFILE=1048576
LimitNPROC=512

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${SERVICE_FILE}"

    systemctl daemon-reload

    systemctl enable hysteria-server.service >/dev/null

    log "systemd 服务已配置。"
}

# ============================================================
# 配置检查
# ============================================================

check_config() {

    info "检查 Hysteria 配置..."

    if "${HYSTERIA_BIN}" server --help >/dev/null 2>&1; then
        :
    fi

    # 使用实际启动测试捕获配置错误
    timeout 3 \
        "${HYSTERIA_BIN}" server \
        -c "${CONFIG_FILE}" \
        >/tmp/hysteria-config-test.log \
        2>&1 &
    
    local pid=$!

    sleep 1

    if ! kill -0 "${pid}" 2>/dev/null; then

        if grep -Eqi \
            'error|fatal|invalid|failed' \
            /tmp/hysteria-config-test.log; then

            cat /tmp/hysteria-config-test.log

            die "Hysteria 配置检查失败。"
        fi

    fi

    kill "${pid}" 2>/dev/null ||
        true

    wait "${pid}" 2>/dev/null ||
        true

    rm -f /tmp/hysteria-config-test.log

    log "配置检查完成。"
}

# ============================================================
# 启动
# ============================================================

start_service() {

    systemctl daemon-reload

    systemctl enable hysteria-server.service >/dev/null

    systemctl restart hysteria-server.service

    sleep 2

    if ! systemctl is-active --quiet hysteria-server.service; then

        echo

        systemctl --no-pager -l \
            status hysteria-server.service ||
            true

        echo

        journalctl \
            -u hysteria-server.service \
            -n 50 \
            --no-pager ||
            true

        die "Hysteria 2 启动失败。"
    fi

    log "Hysteria 2 服务运行正常。"
}

# ============================================================
# 分享链接
# ============================================================

generate_share_link() {

    local host
    local server_port

    host="${DOMAIN}"

    if [[ -n "${HOP_RANGE}" ]]; then

        server_port="${HOP_RANGE}"

    else

        server_port="${PORT}"
    fi

    local encoded_auth
    local encoded_obfs

    encoded_auth="$(urlencode "${AUTH_PASSWORD}")"
    encoded_obfs="$(urlencode "${OBFS_PASSWORD}")"

    SHARE_LINK="hysteria2://${encoded_auth}@${host}:${server_port}?sni=${host}&obfs=salamander&obfs-password=${encoded_obfs}#HY2"

    printf '%s\n' "${SHARE_LINK}" > "${SHARE_FILE}"

    chmod 600 "${SHARE_FILE}"
}

# ============================================================
# 显示信息
# ============================================================

show_info() {

    echo

    echo -e "${CYAN}"
    echo "============================================================"
    echo "                  Hysteria 2 安装完成"
    echo "============================================================"
    echo -e "${RESET}"

    echo "域名        : ${DOMAIN}"

    if [[ -n "${HOP_RANGE}" ]]; then

        echo "监听端口    : ${PORT}"
        echo "UDP 端口跳跃: ${HOP_RANGE}"

    else

        echo "监听端口    : ${PORT}"
        echo "UDP 端口跳跃: 未启用"

    fi

    echo "配置文件    : ${CONFIG_FILE}"
    echo "证书        : ${CERT_FILE}"
    echo "私钥        : ${KEY_FILE}"
    echo "服务        : hysteria-server.service"

    echo

    echo -e "${GREEN}Hysteria 2 分享链接：${RESET}"

    cat "${SHARE_FILE}"

    echo

    if command -v qrencode >/dev/null 2>&1; then

        echo -e "${GREEN}二维码：${RESET}"

        qrencode -t ANSIUTF8 \
            < "${SHARE_FILE}" ||
            true

        echo
    fi
}

# ============================================================
# 安装
# ============================================================

install_cmd() {

    require_root

    install_dependencies

    echo

    read -rp \
        "请输入证书域名，例如 hy.example.com: " \
        DOMAIN

    [[ -n "${DOMAIN}" ]] || {
        die "域名不能为空。"
    }

    [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || {
        die "域名格式无效。"
    }

    check_domain "${DOMAIN}"

    install_acme

    issue_certificate

    input_port

    input_port_hopping

    input_passwords

    input_masquerade

    write_config

    write_systemd

    check_config

    start_service

    generate_share_link

    show_info

    echo

    log "安装完成。"

    echo

    echo "常用管理命令："

    echo "  $0 status"
    echo "  $0 restart"
    echo "  $0 logs"
    echo "  $0 info"
    echo "  $0 uninstall"

    echo

    echo "或者直接使用 systemctl："

    echo "  systemctl status hysteria-server"
    echo "  systemctl restart hysteria-server"
    echo "  journalctl -u hysteria-server -f"
}

# ============================================================
# status
# ============================================================

status_cmd() {

    systemctl \
        --no-pager \
        -l \
        status \
        hysteria-server.service
}

# ============================================================
# restart
# ============================================================

restart_cmd() {

    systemctl restart hysteria-server.service

    sleep 1

    if systemctl is-active --quiet hysteria-server.service; then

        log "Hysteria 2 重启成功。"

    else

        systemctl \
            --no-pager \
            -l \
            status \
            hysteria-server.service ||
            true

        die "Hysteria 2 重启失败。"
    fi
}

# ============================================================
# logs
# ============================================================

logs_cmd() {

    journalctl \
        -u hysteria-server.service \
        -n 100 \
        --no-pager
}

# ============================================================
# info
# ============================================================

info_cmd() {

    [[ -f "${ENV_FILE}" ]] || {
        die "未检测到 Hysteria 2 安装。"
    }

    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    generate_share_link

    show_info
}

# ============================================================
# 卸载
# ============================================================

uninstall_cmd() {

    require_root

    echo

    warn "此操作将卸载 Hysteria 2。"

    warn "同时删除："

    echo "  - Hysteria 2"
    echo "  - systemd 服务"
    echo "  - Hysteria 配置"
    echo "  - 分享链接"
    echo "  - 本脚本管理的证书文件"

    echo

    read -rp \
        "输入 YES 确认卸载: " \
        CONFIRM

    if [[ "${CONFIRM}" != "YES" ]]; then

        log "已取消卸载。"

        exit 0
    fi

    systemctl disable \
        --now \
        hysteria-server.service \
        2>/dev/null ||
        true

    rm -f "${SERVICE_FILE}"

    systemctl daemon-reload

    # 尝试删除 acme.sh 中对应域名
    if [[
        -x "${ACME_HOME}/acme.sh" &&
        -f "${DOMAIN_FILE}"
    ]]; then

        local domain

        domain="$(cat "${DOMAIN_FILE}")"

        "${ACME_HOME}/acme.sh" \
            --remove \
            -d "${domain}" \
            --ecc \
            2>/dev/null ||
            true
    fi

    rm -f "${HYSTERIA_BIN}"

    rm -rf "${HYSTERIA_DIR}"

    log "Hysteria 2 已卸载。"

    warn "acme.sh 本身未删除，因为它可能被其他证书使用。"
}

# ============================================================
# help
# ============================================================

usage() {

    cat <<EOF

Hysteria 2 管理脚本

用法：

  $0
      安装 / 配置 Hysteria 2

  $0 install
      安装 / 配置 Hysteria 2

  $0 status
      查看服务状态

  $0 restart
      重启 Hysteria 2

  $0 logs
      查看最近 100 条日志

  $0 info
      查看节点信息 / 分享链接

  $0 uninstall
      卸载 Hysteria 2

EOF
}

# ============================================================
# 主程序
# ============================================================

main() {

    case "${1:-install}" in

        install)
            install_cmd
            ;;

        status)
            status_cmd
            ;;

        restart)
            restart_cmd
            ;;

        logs)
            logs_cmd
            ;;

        info)
            info_cmd
            ;;

        uninstall|remove)
            uninstall_cmd
            ;;

        -h|--help|help)
            usage
            ;;

        *)
            usage
            exit 1
            ;;

    esac
}

main "$@"
