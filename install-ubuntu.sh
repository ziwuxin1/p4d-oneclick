#!/usr/bin/env bash
#
# P4D One-Click — Ubuntu 全自动部署 Perforce P4D + 自愈 + 备份 + 监控面板
# Target: 全新 Ubuntu 22.04 / 24.04 (x86_64) VPS
#
# 用法:
#   # license 已经传到服务器上
#   sudo bash install-ubuntu.sh --license /root/license
#
#   # 一条命令(license 放在可下载的 URL)
#   curl -fsSL https://raw.githubusercontent.com/ziwuxin1/p4d-oneclick/main/install-ubuntu.sh \
#     | sudo LICENSE_URL='https://example.com/license' bash
#
# 设计原则:
#   - 无人值守: 不问任何问题,密码自动生成,写到 /root/p4d-oneclick-credentials.txt
#   - 先检查再动手: 系统 / 架构 / 内存 / 磁盘 / 端口 / license 不对,什么都不装直接退出
#   - 可重入: 中途失败修好后重跑即可,已完成的部分自动跳过或原地覆盖
#   - 部署逻辑全部复用 p4d-toolkit.sh 的 step_* 函数,这里只负责编排
#

set -o errexit
set -o errtrace   # ERR trap 在函数内也生效,出错时能打印行号
set -o nounset
set -o pipefail

readonly ONECLICK_VERSION="1.0.0"

# ============================================================
#  配置(环境变量可覆盖,命令行参数优先级最高)
# ============================================================

readonly ONECLICK_REPO_RAW="${ONECLICK_REPO_RAW:-https://raw.githubusercontent.com/ziwuxin1/p4d-oneclick/main}"
readonly ONECLICK_HOME="/opt/p4d-oneclick"
readonly ONECLICK_LOG="/var/log/p4d-oneclick.log"
readonly ONECLICK_STATE_DIR="/var/lib/p4d-oneclick"
readonly CREDENTIALS_FILE="/root/p4d-oneclick-credentials.txt"
readonly TOOLKIT_LINK="/usr/local/sbin/p4d-toolkit"

readonly MONITOR_GIT_URL="${MONITOR_GIT_URL:-https://github.com/ziwuxin1/p4d-monitor.git}"
readonly MONITOR_SRC="${ONECLICK_HOME}/src/p4d-monitor"
readonly MONITOR_DIR="/opt/p4d-monitor"
readonly MONITOR_USER="p4d-monitor"
readonly MONITOR_SERVICE="p4d-monitor"
readonly MONITOR_CONFIG="${MONITOR_DIR}/config/config.yaml"
readonly MONITOR_SSH_KEY="/etc/p4d-monitor/ssh_key"

readonly SUPPORTED_UBUNTU="22.04 24.04"
readonly MIN_RAM_MB=1800
readonly MIN_DISK_GB=10
readonly P4D_START_TIMEOUT_S=60
readonly MONITOR_START_TIMEOUT_S=60

LICENSE_FILE="${LICENSE_FILE:-}"
LICENSE_URL="${LICENSE_URL:-}"
INSTALL_MONITOR="${INSTALL_MONITOR:-1}"
MONITOR_PUBLIC="${MONITOR_PUBLIC:-0}"
MONITOR_PORT="${MONITOR_PORT:-8080}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
SKIP_LICENSE_IP_CHECK="${SKIP_LICENSE_IP_CHECK:-0}"
P4_ALLOW_FROM="${P4_ALLOW_FROM:-}"
# 用户显式指定的值(环境变量 / 参数)要压过 /etc/ssh-toolkit.conf 里的旧值
USER_P4PORT="${P4PORT:-}"
USER_NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-}"
# VPS 没有 NAS: 默认把"NAS 副本"放在本机另一个目录,以后挂了外置盘/NFS 再改
export NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-/var/backups/p4d-mirror}"

# 刚开机的 VPS 上 cloud-init / unattended-upgrades 常占着 dpkg 锁。
# 安装期间临时加一个全局 apt 配置让所有 apt(包括 p4d-monitor 的 install.sh)排队等锁,
# 退出时删除。
readonly APT_LOCK_CONF="/etc/apt/apt.conf.d/99p4d-oneclick-lock"
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
# 告警邮件(可选,三个都填才启用)
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

# 运行时状态
LICENSE_STAGED=""
ADMIN_PASSWORD=""
DASHBOARD_PASSWORD=""

# ============================================================
#  启动阶段(toolkit 还没加载)用的最小输出函数
# ============================================================

boot_die() { printf '✗  %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
P4D One-Click — Ubuntu 全自动部署

用法: sudo bash install-ubuntu.sh [选项]

License(必须二选一,或已经装过):
  --license PATH            本机上的 license 文件
  --license-url URL         从 URL 下载 license(https)

可选:
  --p4port PORT             P4D 端口 (默认 1888)
  --no-monitor              不装监控面板
  --monitor-public          面板对公网开放 (默认只监听 127.0.0.1,用 SSH 隧道访问)
  --monitor-port PORT       面板端口 (默认 8080)
  --no-firewall             不动 ufw
  --skip-license-ip-check   license IP 与本机不符时也继续 (P4D 很可能起不来)
  --p4-allow-from CIDR      只允许这个网段连 P4D (例 203.0.113.0/24),默认全网
  -h, --help                显示帮助

环境变量同名可用: LICENSE_FILE LICENSE_URL P4PORT INSTALL_MONITOR MONITOR_PUBLIC
MONITOR_PORT ENABLE_FIREWALL SKIP_LICENSE_IP_CHECK NAS_BACKUP_ROOT P4_ALLOW_FROM
SMTP_USER SMTP_PASSWORD ALERT_EMAIL (Gmail App Password,三个都填才启用告警邮件)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --license)               LICENSE_FILE="${2:?--license 需要路径}"; shift 2 ;;
            --license-url)           LICENSE_URL="${2:?--license-url 需要 URL}"; shift 2 ;;
            --p4port)                export P4PORT="${2:?--p4port 需要端口}"; USER_P4PORT="$P4PORT"; shift 2 ;;
            --no-monitor)            INSTALL_MONITOR=0; shift ;;
            --monitor-public)        MONITOR_PUBLIC=1; shift ;;
            --monitor-port)          MONITOR_PORT="${2:?--monitor-port 需要端口}"; shift 2 ;;
            --no-firewall)           ENABLE_FIREWALL=0; shift ;;
            --skip-license-ip-check) SKIP_LICENSE_IP_CHECK=1; shift ;;
            --p4-allow-from)         P4_ALLOW_FROM="${2:?--p4-allow-from 需要 CIDR}"; shift 2 ;;
            -h|--help)               usage; exit 0 ;;
            *) usage >&2; boot_die "未知参数: $1" ;;
        esac
    done
    if [[ -n "${P4PORT:-}" ]] && ! is_port "$P4PORT"; then boot_die "P4PORT 不合法: $P4PORT"; fi
    is_port "$MONITOR_PORT" || boot_die "MONITOR_PORT 不合法: $MONITOR_PORT"
    if [[ -n "$P4_ALLOW_FROM" && ! "$P4_ALLOW_FROM" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]; then
        boot_die "P4_ALLOW_FROM 不像 IP/CIDR: $P4_ALLOW_FROM"
    fi
}

# 日志 / 屏幕里不打印 URL 的 query string(预签名 URL 里常带 token)
redact_url() { printf '%s' "${1%%\?*}"; }

# ============================================================
#  apt 等锁 — cloud-init 先跑完,再给所有 apt 加锁等待
# ============================================================

prepare_apt() {
    if command -v cloud-init >/dev/null 2>&1; then
        printf 'ℹ  等待 cloud-init 完成 (新 VPS 首次开机可能要几分钟)\n'
        timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
    fi
    printf 'DPkg::Lock::Timeout "900";\nAcquire::Retries "3";\n' > "$APT_LOCK_CONF"
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# ============================================================
#  curl 自举 — 后面下载 toolkit / license / tgz 全靠它
# ============================================================

ensure_curl() {
    if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
        return 0
    fi
    printf 'ℹ  curl 不可用,自动安装\n'
    export DEBIAN_FRONTEND=noninteractive
    if ! { apt-get update -q && apt-get install -y -q curl ca-certificates; }; then
        printf '⚠  curl 安装失败,尝试 reinstall\n'
        apt-get install --reinstall -y -q curl || boot_die "curl reinstall 失败,请手动检查 apt 源"
    fi
    hash -r
    /usr/bin/curl --version >/dev/null 2>&1 || boot_die "/usr/bin/curl 仍不可用"
    printf '✓  curl 就绪: %s\n' "$(/usr/bin/curl --version | head -1)"
}

# ============================================================
#  加载 toolkit(本地优先,否则从 GitHub 拉)
# ============================================================

load_toolkit() {
    mkdir -p "$ONECLICK_HOME"
    local self_dir="" target="${ONECLICK_HOME}/p4d-toolkit.sh"
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [[ -n "$self_dir" && -f "${self_dir}/p4d-toolkit.sh" ]]; then
        [[ "${self_dir}/p4d-toolkit.sh" -ef "$target" ]] || install -m 755 "${self_dir}/p4d-toolkit.sh" "$target"
    else
        local tmp; tmp="$(mktemp)"
        curl -fsSL "${ONECLICK_REPO_RAW}/p4d-toolkit.sh" -o "$tmp" \
            || { rm -f "$tmp"; boot_die "下载 p4d-toolkit.sh 失败: ${ONECLICK_REPO_RAW}/p4d-toolkit.sh"; }
        bash -n "$tmp" || { rm -f "$tmp"; boot_die "下载的 p4d-toolkit.sh 语法检查失败"; }
        install -m 755 "$tmp" "$target"
        rm -f "$tmp"
    fi
    ln -sf "$target" "$TOOLKIT_LINK"

    # shellcheck source=p4d-toolkit.sh
    source "$target"
    export P4D_ASSUME_YES=1
    log_init
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    load_config
    reapply_user_overrides
}

reapply_user_overrides() {
    # load_config 最后 source /etc/ssh-toolkit.conf,会盖掉命令行 / 环境变量 → 显式值优先
    if [[ -n "$USER_P4PORT" && "$USER_P4PORT" != "$P4PORT" ]]; then
        warn "P4PORT: 配置文件里是 $P4PORT,按你指定的改为 $USER_P4PORT"
        P4PORT="$USER_P4PORT"
    fi
    if [[ -n "$USER_NAS_BACKUP_ROOT" && "$USER_NAS_BACKUP_ROOT" != "$NAS_BACKUP_ROOT" ]]; then
        warn "NAS_BACKUP_ROOT: 配置文件里是 $NAS_BACKUP_ROOT,按你指定的改为 $USER_NAS_BACKUP_ROOT"
        NAS_BACKUP_ROOT="$USER_NAS_BACKUP_ROOT"
    fi
}

# 同时写屏幕和 oneclick 日志
step() { section "$*"; printf '[%s] [STEP] %s\n' "$(date '+%F %T')" "$*" >> "$ONECLICK_LOG"; }

# ============================================================
#  1. 预检 — 任何一项不过,什么都不装
# ============================================================

preflight() {
    step "1/8  预检"
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release,不是 Ubuntu?"
    local os_id os_ver
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    # shellcheck disable=SC1091
    os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    [[ "$os_id" == "ubuntu" ]] || die "只支持 Ubuntu,当前: ${os_id:-未知}"
    [[ " $SUPPORTED_UBUNTU " == *" $os_ver "* ]] || die "只支持 Ubuntu $SUPPORTED_UBUNTU,当前: $os_ver"
    ok "系统: Ubuntu $os_ver"

    local arch; arch="$(uname -m)"
    [[ "$arch" == "x86_64" ]] || die "P4D 安装包是 x86_64 版,当前架构 $arch 不支持 (ARM VPS 不行)"
    ok "架构: $arch"

    command -v systemctl >/dev/null || die "没有 systemd"

    local ram_mb; ram_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    (( ram_mb >= MIN_RAM_MB )) || die "内存 ${ram_mb}MB < 最低 ${MIN_RAM_MB}MB"
    ok "内存: ${ram_mb}MB"

    mkdir -p /opt
    local disk_gb; disk_gb="$(df -BG --output=avail /opt | tail -1 | tr -dc '0-9')"
    (( disk_gb >= MIN_DISK_GB )) || die "/opt 可用空间 ${disk_gb}GB < 最低 ${MIN_DISK_GB}GB"
    ok "/opt 可用: ${disk_gb}GB"

    check_port_free "$P4PORT" p4d "P4D"
    if [[ "$INSTALL_MONITOR" == "1" ]]; then
        check_port_free "$MONITOR_PORT" python "监控面板"
    fi
}

check_port_free() {
    # 端口被占用且不是我们自己的服务(重跑场景)→ 退出
    local port="$1" owner_hint="$2" label="$3" holder
    holder="$(ss -Hltnp "sport = :$port" 2>/dev/null || true)"
    if [[ -z "$holder" ]]; then
        ok "$label 端口 $port 空闲"
    elif [[ "$holder" == *"\"$owner_hint"* ]]; then
        ok "$label 端口 $port 已被本工具的服务占用 (重跑)"
    else
        die "$label 端口 $port 被其他程序占用: $holder"
    fi
}

# ============================================================
#  2. License — 必须提供,先验证再装
# ============================================================

stage_license() {
    step "2/8  License"
    LICENSE_STAGED="$(mktemp)"
    chmod 600 "$LICENSE_STAGED"

    if [[ -n "$LICENSE_FILE" ]]; then
        [[ -f "$LICENSE_FILE" ]] || die "license 文件不存在: $LICENSE_FILE"
        cp "$LICENSE_FILE" "$LICENSE_STAGED"
        info "使用本地 license: $LICENSE_FILE"
    elif [[ -n "$LICENSE_URL" ]]; then
        [[ "$LICENSE_URL" == https://* ]] || die "LICENSE_URL 必须是 https://"
        curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 "$LICENSE_URL" -o "$LICENSE_STAGED" \
            || die "下载 license 失败: $(redact_url "$LICENSE_URL")"
        info "已下载 license"
    elif license_present; then
        cp "$P4ROOT/license" "$LICENSE_STAGED"
        info "未指定 license,沿用已安装的 $P4ROOT/license (重跑)"
    else
        die "必须提供 license: --license /path/to/license 或 LICENSE_URL=https://..."
    fi

    [[ -s "$LICENSE_STAGED" ]] || die "license 文件是空的"
    grep -qE '^(License|IPaddress|Users|Customer):' "$LICENSE_STAGED" \
        || die "这不像 Perforce license 文件(缺少 License:/IPaddress:/Users: 字段)"

    local lic_ip users
    lic_ip="$(awk '/^IPaddress:/ {print $2; exit}' "$LICENSE_STAGED" | cut -d: -f1)"
    users="$(awk '/^Users:/ {print $2; exit}' "$LICENSE_STAGED")"
    info "License 用户数: ${users:-未指定}"

    if [[ -z "$lic_ip" ]]; then
        warn "License 没有绑定 IPaddress"
        return 0
    fi
    info "License 绑定 IP: $lic_ip"
    local my_ips; my_ips="$(hostname -I 2>/dev/null || true)"
    if [[ " $my_ips " == *" $lic_ip "* ]]; then
        ok "License IP 与本机网卡匹配"
    elif [[ "$SKIP_LICENSE_IP_CHECK" == "1" ]]; then
        warn "License IP $lic_ip 不在本机网卡上 ($my_ips) — 已按要求跳过检查,P4D 可能拒绝启动"
    else
        err "License IP $lic_ip 不在本机网卡上: $my_ips"
        info "Perforce license 绑定服务器 IP。请用这台 VPS 的 IP 申请/rehost license。"
        info "(有些云厂商公网 IP 是 NAT,不在网卡上 — 这种机器需要用内网 IP 申请 license)"
        die "确认无误可加 --skip-license-ip-check 强制继续"
    fi
}

# ============================================================
#  3. 系统依赖
# ============================================================

install_packages() {
    step "3/8  系统依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >> "$ONECLICK_LOG" 2>&1 || die "apt-get update 失败 (见 $ONECLICK_LOG)"
    apt-get install -y -q curl ca-certificates rsync cron ufw openssl iproute2 sudo \
        git python3 python3-venv python3-pip openssh-client openssh-server \
        >> "$ONECLICK_LOG" 2>&1 || die "apt-get install 失败 (见 $ONECLICK_LOG)"
    systemctl enable --now cron >/dev/null 2>&1 || warn "cron 服务启动失败"
    ok "依赖安装完成"
}

# ============================================================
#  4. P4D 核心(复用 toolkit 步骤 0→4)
# ============================================================

generate_password() {
    # 20 位随机字母数字 + 固定大小写数字后缀,保证满足 security=2 强密码规则
    local rand
    rand="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 20)"
    printf '%sAa9' "$rand"
}

deploy_p4d() {
    step "4/8  P4D 核心 (安装 + license + systemd 自愈 + cron 备份)"
    step_prepare_workspace
    install -m 600 "$LICENSE_STAGED" "${INSTALL_TEMP}/license"
    rm -f "$LICENSE_STAGED"

    step_install_p4d
    step_install_license

    if [[ -s "$P4D_ADMIN_PASSWD_FILE" ]]; then
        ADMIN_PASSWORD="$(cat "$P4D_ADMIN_PASSWD_FILE")"
        info "沿用已有 admin 密码文件 $P4D_ADMIN_PASSWD_FILE"
    else
        ADMIN_PASSWORD="$(generate_password)"
    fi
    export P4D_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    step_setup_systemd_with_rescue
    unset P4D_ADMIN_PASSWORD

    mkdir -p "$NAS_BACKUP_ROOT"
    step_setup_cron_checkpoint
    save_config

    info "启动 $SVC_NAME"
    systemctl restart "$SVC_NAME" || die "P4D 启动失败: journalctl -u $SVC_NAME -n 50"
    wait_for_p4d
}

wait_for_p4d() {
    local i
    for (( i = 0; i < P4D_START_TIMEOUT_S; i++ )); do
        if "$P4_BIN" -p "localhost:$P4PORT" info >/dev/null 2>&1; then
            ok "P4D 已在 localhost:$P4PORT 响应"
            return 0
        fi
        sleep 1
    done
    journalctl -u "$SVC_NAME" -n 30 --no-pager || true
    die "P4D ${P4D_START_TIMEOUT_S}s 内没有响应 (最常见原因: license IP 不符)"
}

# ============================================================
#  5. admin 超级用户 + 安全基线
# ============================================================

p4_admin() { P4TICKETS=/root/.p4tickets_oneclick "$P4_BIN" -p "localhost:$P4PORT" -u admin "$@"; }

bootstrap_admin() {
    step "5/8  admin 超级用户 + 安全基线"
    # "login not necessary" = 用户没设密码,不能当成已配置好
    local login_out=""
    if login_out="$(p4_admin login < "$P4D_ADMIN_PASSWD_FILE" 2>&1)" \
        && [[ "$login_out" != *"not necessary"* ]]; then
        ok "admin 已存在且密码正确 (重跑),跳过创建"
    else
        local other_users
        other_users="$(p4_admin users 2>/dev/null | grep -cv '^admin ' || true)"
        if (( other_users > 0 )); then
            die "服务器已有 $other_users 个其他用户但 admin 登录失败 — 不是全新服务器,拒绝改动。检查 $P4D_ADMIN_PASSWD_FILE"
        fi
        info "创建 admin 用户"
        p4_admin user -o | p4_admin user -i >/dev/null
        printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | p4_admin passwd >/dev/null
        p4_admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null || die "admin 设置密码后登录失败"
        ok "admin 已创建"
    fi

    # 全新服务器的 protect 表是空的 = 所有人都是 super。只在第一次部署时收紧,
    # 之后用户自己改过的 protect 表重跑不覆盖(靠标记文件,不靠猜输出)。
    local protect_marker="${ONECLICK_STATE_DIR}/protect.done"
    if [[ ! -f "$protect_marker" ]]; then
        info "设置 protect 表: 只有 admin 是 super"
        printf 'Protections:\n\tsuper user admin * //...\n' | p4_admin protect -i >/dev/null
        mkdir -p "$ONECLICK_STATE_DIR"
        date -Iseconds > "$protect_marker"
        ok "protect 已设置 (加用户/组: sudo p4 -u admin protect)"
    else
        ok "protect 表之前已初始化,保持不动"
    fi

    # 公网 VPS 安全基线
    p4_admin configure set security=2 >/dev/null              # 强制强密码 + 必须设密码
    p4_admin configure set dm.user.noautocreate=2 >/dev/null  # 禁止陌生人连上就自动建用户
    p4_admin configure set run.users.authorize=1 >/dev/null   # 未登录不能列用户
    ok "security=2, dm.user.noautocreate=2, run.users.authorize=1"
}

# ============================================================
#  6. 首次备份(不用等到 03:00,同时验证备份链路)
# ============================================================

initial_backup() {
    step "6/8  首次 checkpoint + 镜像"
    step_run_checkpoint_now
    if ! compgen -G "${BACKUP_DIR}/checkpoint.*" >/dev/null; then
        warn "checkpoint 没出现在 $BACKUP_DIR — 检查 toolkit 的 p4d -jc 参数"
        find "$P4ROOT" -maxdepth 1 -name 'checkpoint.*' -printf '    发现: %p\n' 2>/dev/null || true
    fi
    step_run_rsync_now || warn "首次 rsync 失败,03:30 的 cron 会再试"
}

# ============================================================
#  7. 监控面板(p4d-monitor)
# ============================================================

yaml_quote() {
    # JSON 字符串就是合法的 YAML 双引号字符串,转义交给 python 最稳
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

sshd_ports() {
    # 三个来源取并集: sshd 配置 / Ubuntu 24.04 的 ssh.socket / 实际在监听的 sshd 进程。
    # 只看 sshd -T 不够: socket 激活时改端口写在 ssh.socket drop-in 里,sshd -T 仍报 22。
    {
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
        systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': '
        ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
        [[ -n "${SSH_CONNECTION:-}" ]] && echo "${SSH_CONNECTION##* }"
    } | grep -E '^[0-9]+$' | sort -un || true
}

deploy_monitor() {
    step "7/8  监控面板"
    if [[ "$INSTALL_MONITOR" != "1" ]]; then
        info "已跳过 (--no-monitor)"
        return 0
    fi

    mkdir -p "$(dirname "$MONITOR_SRC")"
    if [[ -d "$MONITOR_SRC/.git" ]]; then
        git -C "$MONITOR_SRC" fetch -q --depth 1 origin main
        git -C "$MONITOR_SRC" reset -q --hard origin/main
    else
        git clone -q --depth 1 "$MONITOR_GIT_URL" "$MONITOR_SRC" || die "clone 失败: $MONITOR_GIT_URL"
    fi
    ok "代码: $MONITOR_SRC ($(git -C "$MONITOR_SRC" rev-parse --short HEAD))"

    info "运行 p4d-monitor/install.sh (输出写入 $ONECLICK_LOG)"
    ( cd "$MONITOR_SRC" && bash install.sh ) >> "$ONECLICK_LOG" 2>&1 \
        || die "p4d-monitor install.sh 失败 (见 $ONECLICK_LOG)"

    write_monitor_config
    authorize_monitor_ssh

    systemctl restart "$MONITOR_SERVICE" || die "监控面板启动失败: journalctl -u $MONITOR_SERVICE -n 50"
    local i code
    for (( i = 0; i < MONITOR_START_TIMEOUT_S; i++ )); do
        # 任何 HTTP 响应(200 / 302 跳登录页)都算起来了;000 = 连不上
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MONITOR_PORT}/" || true)"
        if [[ "$code" != "000" ]]; then
            ok "监控面板已在 :$MONITOR_PORT 响应"
            return 0
        fi
        sleep 1
    done
    warn "监控面板 ${MONITOR_START_TIMEOUT_S}s 内没响应: journalctl -u $MONITOR_SERVICE -n 50"
}

write_monitor_config() {
    # 已经配置过登录密码 → 保留(重跑不覆盖用户改过的配置)
    if [[ -f "$MONITOR_CONFIG" ]] && grep -qE '^\s*password_hash:\s*"?\$2' "$MONITOR_CONFIG"; then
        ok "面板配置已存在,保持不动: $MONITOR_CONFIG"
        return 0
    fi

    DASHBOARD_PASSWORD="$(generate_password)"
    local hash secret bind_host email_enabled="false"
    hash="$(DASH_PW="$DASHBOARD_PASSWORD" "$MONITOR_DIR/venv/bin/python3" -c \
        'import bcrypt,os;print(bcrypt.hashpw(os.environ["DASH_PW"].encode(),bcrypt.gensalt()).decode())')"
    secret="$(openssl rand -hex 32)"
    bind_host="127.0.0.1"
    [[ "$MONITOR_PUBLIC" == "1" ]] && bind_host="0.0.0.0"
    [[ -n "$SMTP_USER" && -n "$SMTP_PASSWORD" && -n "$ALERT_EMAIL" ]] && email_enabled="true"

    local ssh_port; ssh_port="$(sshd_ports | head -1)"
    ssh_port="${ssh_port:-22}"
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# 由 p4d-oneclick install-ubuntu.sh 生成 $(date -Iseconds)
dashboard:
  host: $bind_host
  port: $MONITOR_PORT
  username: admin
  password_hash: $(yaml_quote "$hash")
  secret_key: $(yaml_quote "$secret")

probe:
  interval_seconds: 300
  ssh_timeout: 10
  ssh_key_path: $MONITOR_SSH_KEY

servers:
  - name: $(yaml_quote "$(hostname)")
    host: 127.0.0.1
    ssh_port: $ssh_port
    ssh_user: root
    p4d_port: $P4PORT
    p4d_root: $P4ROOT
    backup_dir: $BACKUP_DIR
    nas_dir: $NAS_BACKUP_ROOT

email:
  enabled: $email_enabled
  smtp_host: smtp.gmail.com
  smtp_port: 587
  smtp_user: $(yaml_quote "$SMTP_USER")
  smtp_password: $(yaml_quote "$SMTP_PASSWORD")
  from_addr: $(yaml_quote "${SMTP_USER:+P4D Monitor <$SMTP_USER>}")
  to_addr: $(yaml_quote "$ALERT_EMAIL")

alerts:
  daily_summary_time: "09:00"
  recovery_notification: true
  cooldown_minutes: 30
  thresholds:
    checkpoint_age_hours: 26
    nas_age_hours: 26
    disk_pct_warn: 80
    disk_pct_critical: 90
EOF
    install -m 640 -o "$MONITOR_USER" -g "$MONITOR_USER" "$tmp" "$MONITOR_CONFIG"
    rm -f "$tmp"
    ok "面板配置已生成: $MONITOR_CONFIG (邮件告警: $email_enabled)"
}

authorize_monitor_ssh() {
    # 面板通过 SSH 探测本机: 公钥只允许从 127.0.0.1 登录 root,禁止转发
    [[ -f "${MONITOR_SSH_KEY}.pub" ]] || die "找不到面板 SSH 公钥 ${MONITOR_SSH_KEY}.pub"
    local pub line auth=/root/.ssh/authorized_keys
    pub="$(cat "${MONITOR_SSH_KEY}.pub")"
    line="from=\"127.0.0.1,::1\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ${pub}"
    install -d -m 700 /root/.ssh
    touch "$auth"
    chmod 600 "$auth"
    if grep -qF "$pub" "$auth"; then
        ok "面板公钥已在 $auth"
    else
        if [[ -s "$auth" && -n "$(tail -c1 "$auth")" ]]; then
            printf '\n' >> "$auth"
        fi
        printf '%s\n' "$line" >> "$auth"
        ok "面板公钥已加入 $auth (仅限 127.0.0.1)"
    fi

    local prl; prl="$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}' || true)"
    if [[ "$prl" == "no" ]]; then
        warn "sshd PermitRootLogin=no — 面板无法 SSH 探测本机,需改成 prohibit-password"
    fi
}

# ============================================================
#  8. 防火墙
# ============================================================

configure_firewall() {
    step "8/8  防火墙"
    if [[ "$ENABLE_FIREWALL" != "1" ]]; then
        info "已跳过 (--no-firewall) — 记得自己放行 SSH 和 $P4PORT"
        return 0
    fi
    # 先放行 SSH 再启用,避免把自己锁在外面。确认不了 SSH 端口就不启用。
    local port ssh_ports
    ssh_ports="$(sshd_ports)"
    if [[ -z "$ssh_ports" ]]; then
        warn "检测不到 SSH 端口 — 为防止把你锁在外面,不启用 ufw。请手动放行 SSH 后 ufw enable"
        return 0
    fi
    for port in $ssh_ports; do
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null
        ok "放行 SSH ${port}/tcp"
    done
    if [[ -n "$P4_ALLOW_FROM" ]]; then
        ufw allow from "$P4_ALLOW_FROM" to any port "$P4PORT" proto tcp comment 'Perforce' >/dev/null
        ok "放行 P4D ${P4PORT}/tcp (仅限 $P4_ALLOW_FROM)"
    else
        ufw allow "${P4PORT}/tcp" comment 'Perforce' >/dev/null
        ok "放行 P4D ${P4PORT}/tcp (全网)"
    fi
    if [[ "$INSTALL_MONITOR" == "1" && "$MONITOR_PUBLIC" == "1" ]]; then
        ufw allow "${MONITOR_PORT}/tcp" comment 'p4d-monitor' >/dev/null
        warn "面板 ${MONITOR_PORT}/tcp 对公网开放 (HTTP 明文,建议改用 SSH 隧道或 Tailscale)"
    else
        # p4d-monitor 自己的 install.sh 在 ufw 已启用时会放行面板端口,这里收回
        ufw delete allow "${MONITOR_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    ufw --force enable >/dev/null
    ok "ufw 已启用"
    info "云厂商的安全组 / 防火墙 也要放行 ${P4PORT}/tcp (ufw 管不到那一层)"
}

# ============================================================
#  收尾
# ============================================================

write_credentials() {
    local ip; ip="$(hostname -I | awk '{print $1}')"
    local old_umask; old_umask="$(umask)"
    umask 077
    {
        echo "# P4D One-Click 凭据 — $(date -Iseconds)  (只有 root 可读,看完建议转存密码管理器)"
        echo "P4PORT=${ip}:${P4PORT}"
        echo "P4USER=admin"
        echo "P4 admin 密码文件=${P4D_ADMIN_PASSWD_FILE}"
        [[ -n "$ADMIN_PASSWORD" ]] && echo "P4 admin 密码=${ADMIN_PASSWORD}"
        if [[ "$INSTALL_MONITOR" == "1" ]]; then
            echo "面板=http://$([[ "$MONITOR_PUBLIC" == "1" ]] && echo "$ip" || echo 127.0.0.1):${MONITOR_PORT}"
            echo "面板用户=admin"
            if [[ -n "$DASHBOARD_PASSWORD" ]]; then
                echo "面板密码=${DASHBOARD_PASSWORD}"
            else
                echo "面板密码=(沿用之前生成的,见旧版本此文件)"
            fi
        fi
    } > "${CREDENTIALS_FILE}.new"
    umask "$old_umask"
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        cp -p "$CREDENTIALS_FILE" "${CREDENTIALS_FILE}.$(date +%Y%m%d%H%M%S).bak"
    fi
    mv "${CREDENTIALS_FILE}.new" "$CREDENTIALS_FILE"
}

print_summary() {
    local ip; ip="$(hostname -I | awk '{print $1}')"
    step "体检"
    step_health_check || true

    printf "\n${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════${C_RESET}\n"
    printf "${C_BOLD}  P4D One-Click v%s 部署完成${C_RESET}\n" "$ONECLICK_VERSION"
    printf "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════${C_RESET}\n\n"
    printf "  P4PORT     %s:%s\n" "$ip" "$P4PORT"
    printf "  P4USER     admin\n"
    printf "  凭据       %s  (sudo cat 查看)\n" "$CREDENTIALS_FILE"
    printf "  菜单       sudo p4d-toolkit\n"
    printf "  日志       %s\n" "$ONECLICK_LOG"
    printf "  备份       每天 03:00 checkpoint → %s,03:30 镜像 → %s\n" "$BACKUP_DIR" "$NAS_BACKUP_ROOT"
    if [[ "$INSTALL_MONITOR" == "1" ]]; then
        if [[ "$MONITOR_PUBLIC" == "1" ]]; then
            printf "  面板       http://%s:%s\n" "$ip" "$MONITOR_PORT"
        else
            printf "  面板       本机 127.0.0.1:%s,在你电脑上开隧道:\n" "$MONITOR_PORT"
            printf "             ssh -L %s:127.0.0.1:%s root@%s  然后浏览器开 http://localhost:%s\n" \
                "$MONITOR_PORT" "$MONITOR_PORT" "$ip" "$MONITOR_PORT"
        fi
    fi
    printf "\n  ⚠ %s 是本机目录,不是异地备份。挂好外置盘/NFS 后改 /etc/ssh-toolkit.conf 的 NAS_BACKUP_ROOT\n" \
        "$NAS_BACKUP_ROOT"
    printf "  ⚠ P4 协议目前是明文 (密码和 ticket 走公网不加密)。建议用 --p4-allow-from 限制来源 IP,\n"
    printf "    或走 Tailscale / VPN;正式使用前考虑启用 ssl: (p4d -Gc)\n\n"
}

on_error() {
    local rc=$? line="$1" file="$2"
    printf '\n✗  %s 第 %s 行出错 (exit %s)。修好后直接重跑本脚本即可,已完成部分会跳过。日志: %s\n' \
        "$file" "$line" "$rc" "$ONECLICK_LOG" >&2
    exit "$rc"
}

cleanup() {
    # die() 直接 exit 不触发 ERR,所以清理放在 EXIT trap
    if [[ -n "$LICENSE_STAGED" ]]; then rm -f "$LICENSE_STAGED"; fi
    rm -f "$APT_LOCK_CONF"
}

main() {
    [[ $EUID -eq 0 ]] || boot_die "需要 root: sudo bash install-ubuntu.sh ..."
    parse_args "$@"
    touch "$ONECLICK_LOG" && chmod 600 "$ONECLICK_LOG"
    trap 'on_error $LINENO "${BASH_SOURCE[0]:-install-ubuntu.sh}"' ERR
    trap cleanup EXIT
    prepare_apt
    ensure_curl
    load_toolkit

    printf "${C_BOLD}P4D One-Click v%s${C_RESET} (toolkit v%s, P4D %s)\n" \
        "$ONECLICK_VERSION" "$TOOLKIT_VERSION" "$P4D_VERSION"
    preflight
    stage_license
    install_packages
    deploy_p4d
    bootstrap_admin
    initial_backup
    deploy_monitor
    configure_firewall
    write_credentials
    print_summary
}

main "$@"
