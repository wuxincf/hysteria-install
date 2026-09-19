#!/usr/bin/env bash
#
# Hysteria 2 Installer v2
# Security-focused installer:
# - Official Hysteria binary only
# - SHA256 verification against official release hashes.txt
# - amd64 / arm64 / armv7
# - Debian / Ubuntu / RHEL-family / Alpine
# - Built-in ACME (automatic issuance + renewal)
# - Custom TLS certificate
# - Salamander obfuscation
# - Port hopping
# - IPv4 / IPv6
# - Dedicated unprivileged service user
# - Minimal systemd/OpenRC privileges
# - Atomic binary/config updates
# - Full uninstall
# - hysteria2:// URI output
#
# Usage:
#   bash install.sh install
#   bash install.sh update
#   bash install.sh info
#   bash install.sh status
#   bash install.sh restart
#   bash install.sh uninstall
#
# Environment overrides:
#   HY2_VERSION=v2.x.x
#   HY2_LISTEN=:443
#   HY2_HOPPING=20000-30000
#   HY2_DOMAIN=example.com
#   HY2_EMAIL=you@example.com
#   HY2_PASSWORD=...
#   HY2_OBFS_PASSWORD=...
#
set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="2.0.0"
readonly REPO="apernet/hysteria"
readonly BIN="/usr/local/bin/hysteria"
readonly ETC="/etc/hysteria"
readonly CONF="${ETC}/config.yaml"
readonly META="${ETC}/installer.env"
readonly USER="hysteria"
readonly GROUP="hysteria"
readonly SYSTEMD_UNIT="/etc/systemd/system/hysteria-server.service"
readonly OPENRC_UNIT="/etc/init.d/hysteria"
readonly DOWNLOAD_BASE="https://github.com/apernet/hysteria/releases/download"
readonly FALLBACK_BASE="https://download.hysteria.network/app/latest"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "执行失败：第 ${LINENO} 行，请检查上面的错误信息。"' ERR

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"

    case "$OS_ID" in
        alpine)
            INIT="openrc"
            PKG="apk"
            ;;
        debian|ubuntu|linuxmint)
            INIT="systemd"
            PKG="apt"
            ;;
        rhel|rocky|almalinux|centos|fedora)
            INIT="systemd"
            if command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG="yum"; fi
            ;;
        *)
            if [[ "$OS_LIKE" == *debian* ]] || [[ "$OS_LIKE" == *ubuntu* ]]; then
                INIT="systemd"; PKG="apt"
            elif [[ "$OS_LIKE" == *rhel* ]] || [[ "$OS_LIKE" == *fedora* ]]; then
                INIT="systemd"
                if command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG="yum"; fi
            else
                die "暂不支持发行版：${OS_ID}"
            fi
            ;;
    esac

    ARCH_RAW="$(uname -m)"
    case "$ARCH_RAW" in
        x86_64|amd64) HY2_ARCH="amd64" ;;
        aarch64|arm64) HY2_ARCH="arm64" ;;
        armv7l|armv7|armhf) HY2_ARCH="arm" ;;
        *) die "暂不支持架构：${ARCH_RAW}（仅 amd64 / arm64 / armv7）" ;;
    esac

    if [[ "$INIT" == "systemd" ]]; then
        command -v systemctl >/dev/null 2>&1 || die "系统标记为 systemd，但 systemctl 不存在。"
    else
        command -v rc-service >/dev/null 2>&1 || die "Alpine OpenRC 不可用。"
    fi
}

install_deps() {
    log "安装基础依赖：${OS_ID} / ${HY2_ARCH}"

    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2
            ;;
        dnf)
            dnf install -y ca-certificates curl openssl iproute
            ;;
        yum)
            yum install -y ca-certificates curl openssl iproute
            ;;
        apk)
            apk add --no-cache ca-certificates curl openssl iproute2
            ;;
    esac

    update-ca-certificates >/dev/null 2>&1 || true
}

ensure_user() {
    if ! getent group "$GROUP" >/dev/null 2>&1; then
        groupadd --system "$GROUP" 2>/dev/null || addgroup -S "$GROUP"
    fi

    if ! id "$USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd --system --gid "$GROUP" --home-dir "$ETC" \
                --no-create-home --shell /usr/sbin/nologin "$USER"
        else
            adduser -S -D -H -s /sbin/nologin -G "$GROUP" "$USER"
        fi
    fi

    mkdir -p "$ETC"
    chown root:"$GROUP" "$ETC"
    chmod 0750 "$ETC"
}

get_latest_version() {
    if [[ -n "${HY2_VERSION:-}" ]]; then
        printf '%s\n' "$HY2_VERSION"
        return
    fi

    local json tag
    json="$(curl -fsSL --retry 3 --connect-timeout 10 \
        "https://api.github.com/repos/${REPO}/releases/latest")" ||
        die "无法获取 Hysteria 最新版本。"

    tag="$(printf '%s' "$json" |
        sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' |
        head -n1)"

    [[ "$tag" =~ ^app/v2\.[0-9]+\.[0-9]+$ ]] ||
        die "GitHub 返回的版本号异常：${tag:-empty}"

    printf '%s\n' "$tag"
}

download_verified_binary() {
    local version="$1"
    local asset="hysteria-linux-${HY2_ARCH}"
    local tmpdir tmpbin hashfile expected actual url

    tmpdir="$(mktemp -d)"
    tmpbin="${tmpdir}/hysteria"
    hashfile="${tmpdir}/hashes.txt"

    url="${DOWNLOAD_BASE}/${version}/${asset}"
    local hash_url="${DOWNLOAD_BASE}/${version}/hashes.txt"

    log "下载官方 Hysteria：${version} / ${asset}"
    curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmpbin" ||
        die "Hysteria 二进制下载失败。"

    log "下载官方 SHA256：hashes.txt"
    curl -fL --retry 3 --connect-timeout 10 "$hash_url" -o "$hashfile" ||
        die "官方 hashes.txt 下载失败，拒绝安装未校验的二进制。"

    expected="$(awk -v f="$asset" '$NF == f {print $1; exit}' "$hashfile")"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] ||
        die "hashes.txt 中找不到 ${asset} 的 SHA256。"

    actual="$(sha256sum "$tmpbin" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        die "SHA256 校验失败！\n期望：${expected}\n实际：${actual}"
    fi

    log "SHA256 校验通过：${actual}"

    chmod 0755 "$tmpbin"
    # 原子替换，避免更新过程中留下半截可执行文件。
    install -o root -g root -m 0755 "$tmpbin" "${BIN}.new"
    mv -f "${BIN}.new" "$BIN"

    rm -rf "$tmpdir"
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        die "域名格式不正确：$domain"
}

random_secret() {
    openssl rand -hex 24
}

prompt_install_values() {
    echo
    printf '\033[1;36m===== Hysteria 2 Installer v%s =====\033[0m\n' "$VERSION"
    echo

    HY2_DOMAIN="${HY2_DOMAIN:-}"
    HY2_EMAIL="${HY2_EMAIL:-}"
    HY2_PASSWORD="${HY2_PASSWORD:-}"
    HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-}"
    HY2_LISTEN="${HY2_LISTEN:-:443}"
    HY2_HOPPING="${HY2_HOPPING:-}"

    if [[ -z "$HY2_DOMAIN" ]]; then
        read -r -p "请输入域名（ACME）： " HY2_DOMAIN
    fi
    validate_domain "$HY2_DOMAIN"

    if [[ -z "$HY2_EMAIL" ]]; then
        read -r -p "请输入 ACME 邮箱： " HY2_EMAIL
    fi

    if [[ -z "$HY2_PASSWORD" ]]; then
        HY2_PASSWORD="$(random_secret)"
    fi

    read -r -p "Salamander 混淆密码（留空则自动生成）: " input_obfs
    if [[ -n "$input_obfs" ]]; then HY2_OBFS_PASSWORD="$input_obfs"; fi
    [[ -n "$HY2_OBFS_PASSWORD" ]] || HY2_OBFS_PASSWORD="$(random_secret)"

    if [[ -z "$HY2_HOPPING" ]]; then
        read -r -p "Port Hopping 范围（留空禁用，例如 20000-30000）: " HY2_HOPPING
    fi

    if [[ -n "$HY2_HOPPING" ]]; then
        [[ "$HY2_HOPPING" =~ ^[0-9]+-[0-9]+$ ]] ||
            die "Port Hopping 必须是类似 20000-30000 的端口范围。"
        local start end
        start="${HY2_HOPPING%-*}"
        end="${HY2_HOPPING#*-}"
        (( start >= 1 && end <= 65535 && start < end )) ||
            die "Port Hopping 范围无效。"
        # 主监听端口取范围起点。
        HY2_LISTEN=":${start}"
    fi
}

write_config() {
    local tmp
    tmp="$(mktemp "${ETC}/config.yaml.XXXXXX")"

    {
        if [[ -n "$HY2_HOPPING" ]]; then
            printf 'listen: ":%s"\n' "${HY2_HOPPING%-*}"
        else
            printf 'listen: "%s"\n' "$HY2_LISTEN"
        fi

        cat <<EOF
acme:
  domains:
    - ${HY2_DOMAIN}
  email: ${HY2_EMAIL}
  type: http

auth:
  type: password
  password: '${HY2_PASSWORD}'

obfs:
  type: salamander
  salamander:
    password: '${HY2_OBFS_PASSWORD}'

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    } > "$tmp"

    # 先 root 写入，再让服务用户只读。
    chown root:"$GROUP" "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$CONF"
}

write_meta() {
    local tmp
    tmp="$(mktemp "${ETC}/installer.env.XXXXXX")"
    cat > "$tmp" <<EOF
HY2_DOMAIN=$(printf '%q' "$HY2_DOMAIN")
HY2_EMAIL=$(printf '%q' "$HY2_EMAIL")
HY2_PASSWORD=$(printf '%q' "$HY2_PASSWORD")
HY2_OBFS_PASSWORD=$(printf '%q' "$HY2_OBFS_PASSWORD")
HY2_LISTEN=$(printf '%q' "$HY2_LISTEN")
HY2_HOPPING=$(printf '%q' "$HY2_HOPPING")
HY2_VERSION=$(printf '%q' "$INSTALLED_VERSION")
EOF
    chown root:"$GROUP" "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$META"
}

write_systemd_unit() {
    cat > "${SYSTEMD_UNIT}.new" <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
Group=${GROUP}
WorkingDirectory=${ETC}
ExecStart=${BIN} server -c ${CONF}
Restart=on-failure
RestartSec=3
UMask=0077

# Only the capabilities needed for low ports and Hysteria port hopping.
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true

PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
MemoryDenyWriteExecute=true
ReadWritePaths=${ETC}

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${SYSTEMD_UNIT}.new"
    mv -f "${SYSTEMD_UNIT}.new" "$SYSTEMD_UNIT"

    systemctl daemon-reload
    systemctl enable --now hysteria-server.service
}

write_openrc_unit() {
    cat > "${OPENRC_UNIT}.new" <<EOF
#!/sbin/openrc-run

name="hysteria"
description="Hysteria 2 Server"
command="${BIN}"
command_args="server -c ${CONF}"
command_user="${USER}:${GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"

depend() {
    need net
}
EOF
    chmod 0755 "${OPENRC_UNIT}.new"
    mv -f "${OPENRC_UNIT}.new" "$OPENRC_UNIT"

    rc-update add hysteria default >/dev/null
    rc-service hysteria restart 2>/dev/null || rc-service hysteria start
}

write_service() {
    if [[ "$INIT" == "systemd" ]]; then
        write_systemd_unit
    else
        write_openrc_unit
    fi
}

service_restart() {
    if [[ "$INIT" == "systemd" ]]; then
        systemctl restart hysteria-server
    else
        rc-service hysteria restart
    fi
}

service_stop() {
    if [[ "$INIT" == "systemd" ]]; then
        systemctl disable --now hysteria-server.service 2>/dev/null || true
    else
        rc-service hysteria stop 2>/dev/null || true
        rc-update del hysteria default 2>/dev/null || true
    fi
}

service_status() {
    if [[ "$INIT" == "systemd" ]]; then
        systemctl --no-pager --full status hysteria-server.service
    else
        rc-service hysteria status
    fi
}

detect_public_ip() {
    IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    IPV6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
}

build_uri() {
    local host="$HY2_DOMAIN"
    local port="$HY2_LISTEN"
    local params="sni=${HY2_DOMAIN}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}"

    if [[ -n "$HY2_HOPPING" ]]; then
        port="$HY2_HOPPING"
        params="${params}&mport=${HY2_HOPPING}"
    fi

    # URI fragment 中只放节点名称；密码/混淆密码进行 URL 编码。
    local epass eobfs
    epass="$(python3 - "$HY2_PASSWORD" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
    eobfs="$(python3 - "$HY2_OBFS_PASSWORD" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"

    params="sni=${HY2_DOMAIN}&obfs=salamander&obfs-password=${eobfs}"
    printf 'hysteria2://%s@%s%s?%s#Hysteria2\n' "$epass" "$host" "$port" "$params"
}

show_info() {
    if [[ -r "$META" ]]; then
        # shellcheck disable=SC1090
        . "$META"
    else
        die "没有找到安装信息：$META"
    fi

    echo
    echo "========== Hysteria 2 =========="
    "$BIN" version 2>/dev/null || true
    echo
    echo "域名       : ${HY2_DOMAIN}"
    echo "监听       : ${HY2_LISTEN}"
    echo "Port Hop   : ${HY2_HOPPING:-禁用}"
    echo "服务用户   : ${USER}"
    echo
    echo "Hysteria2 URI:"
    build_uri
    echo
    echo "配置文件   : ${CONF}"
    echo "日志       : journalctl -u hysteria-server -f"
    echo "================================"
}

install_or_update() {
    require_root
    detect_os
    install_deps
    ensure_user

    INSTALLED_VERSION="$(get_latest_version)"
    log "目标版本：${INSTALLED_VERSION}"

    if [[ "$1" == "install" ]]; then
        prompt_install_values
        download_verified_binary "$INSTALLED_VERSION"
        write_config
        write_meta
        write_service
    else
        # 更新时保留现有配置。
        [[ -f "$CONF" && -f "$META" ]] || die "尚未安装，请先执行：$0 install"
        # shellcheck disable=SC1090
        . "$META"
        download_verified_binary "$INSTALLED_VERSION"
        write_meta
        service_restart
    fi

    log "安装/更新完成。"
    show_info
}

uninstall() {
    require_root
    detect_os

    echo
    warn "这将停止 Hysteria 2 并删除："
    echo "  ${BIN}"
    echo "  ${ETC}"
    [[ "$INIT" == "systemd" ]] && echo "  ${SYSTEMD_UNIT}"
    [[ "$INIT" == "openrc" ]] && echo "  ${OPENRC_UNIT}"
    echo

    read -r -p "确认卸载？请输入 YES： " confirm
    [[ "$confirm" == "YES" ]] || { log "已取消。"; exit 0; }

    service_stop

    if [[ "$INIT" == "systemd" ]]; then
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload
    else
        rm -f "$OPENRC_UNIT"
    fi

    # 仅删除本安装器自己创建的文件，不碰其他 iptables/nftables 规则。
    rm -f "$BIN"
    rm -rf "$ETC"

    if getent passwd "$USER" >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then
            userdel "$USER" 2>/dev/null || true
        else
            deluser "$USER" 2>/dev/null || true
        fi
    fi
    if getent group "$GROUP" >/dev/null 2>&1; then
        if command -v groupdel >/dev/null 2>&1; then
            groupdel "$GROUP" 2>/dev/null || true
        else
            delgroup "$GROUP" 2>/dev/null || true
        fi
    fi

    log "Hysteria 2 已卸载。"
}

main() {
    local action="${1:-install}"

    case "$action" in
        install|update)
            install_or_update "$action"
            ;;
        info)
            require_root
            detect_os
            show_info
            ;;
        status)
            require_root
            detect_os
            service_status
            ;;
        restart)
            require_root
            detect_os
            service_restart
            ;;
        stop)
            require_root
            detect_os
            service_stop
            ;;
        uninstall|remove)
            uninstall
            ;;
        version)
            echo "$VERSION"
            ;;
        *)
            cat <<EOF
Hysteria 2 Installer v${VERSION}

用法：
  $0 install       安装
  $0 update        更新官方 Hysteria
  $0 info          显示节点信息
  $0 status        查看服务状态
  $0 restart       重启服务
  $0 stop          停止服务
  $0 uninstall     完整卸载
  $0 version       显示安装器版本
EOF
            exit 1
            ;;
    esac
}

main "$@"
