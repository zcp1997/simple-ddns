#!/bin/bash
# =============================================================
#  DDNS 一键交互式配置脚本
#  适配: https://github.com/zcp1997/simple-ddns
# =============================================================

set -uo pipefail

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 工具函数 ───────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
title()   { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

# ── 读取带默认值的输入 ─────────────────────────────────────────
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local secret="${4:-false}"
    local value=""

    while true; do
        if [[ -n "$default" ]]; then
            echo -ne "${BOLD}$prompt_text${NC} [默认: ${YELLOW}$default${NC}]: "
        else
            echo -ne "${BOLD}$prompt_text${NC}: "
        fi

        if [[ "$secret" == "true" ]]; then
            read -rs value; echo
        else
            read -r value
        fi

        value="${value:-$default}"
        if [[ -n "$value" ]]; then
            printf -v "$var_name" '%s' "$value"
            return 0
        else
            error "此项不能为空，请重新输入。"
        fi
    done
}

# ── 校验函数 ───────────────────────────────────────────────────
validate_domain() {
    local d="$1"
    # 基本域名格式：至少两段，每段字母数字或连字符，不以连字符开头/结尾
    if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

validate_subdomain() {
    local s="$1"
    # 允许 @（根域名）或合法子域名标签（支持多级，如 vpn.home）
    if [[ "$s" == "@" ]] || [[ "$s" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

validate_record_type() {
    local r="${1^^}"
    [[ "$r" == "A" || "$r" == "AAAA" ]]
}

validate_cron_interval() {
    local n="$1"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 60 )); then
        return 0
    fi
    return 1
}

validate_cf_token() {
    local t="$1"
    # Cloudflare API Token 通常为 40 位字母数字字符
    if [[ ${#t} -ge 20 ]]; then
        return 0
    fi
    return 1
}

# ── 检测脚本是否存在 ───────────────────────────────────────────
check_ddns_script() {
    local script_path="$1"
    if [[ ! -f "$script_path" ]]; then
        warn "未在 $script_path 找到 ddns.sh"
        echo -ne "${BOLD}是否现在自动下载？${NC} [Y/n]: "
        read -r answer
        answer="${answer:-Y}"
        if [[ "${answer^^}" == "Y" ]]; then
            info "正在下载 ddns.sh ..."
            if command -v wget &>/dev/null; then
                wget -q -O "$script_path" \
                    "https://raw.githubusercontent.com/zcp1997/simple-ddns/main/ddns.sh" \
                    && chmod +x "$script_path" \
                    && success "ddns.sh 已下载并赋予执行权限。"
            elif command -v curl &>/dev/null; then
                curl -fsSL -o "$script_path" \
                    "https://raw.githubusercontent.com/zcp1997/simple-ddns/main/ddns.sh" \
                    && chmod +x "$script_path" \
                    && success "ddns.sh 已下载并赋予执行权限。"
            else
                error "未找到 wget 或 curl，无法自动下载，请手动下载后重试。"
                exit 1
            fi
        else
            error "ddns.sh 不存在，退出。"
            exit 1
        fi
    else
        success "找到 ddns.sh: $script_path"
    fi
}

# ══════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════
clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
 ____  ____  _   _ ____    ____       _               
|  _ \|  _ \| \ | / ___|  / ___|  ___| |_ _   _ _ __  
| | | | | | |  \| \___ \  \___ \ / _ \ __| | | | '_ \ 
| |_| | |_| | |\  |___) |  ___) |  __/ |_| |_| | |_) |
|____/|____/|_| \_|____/  |____/ \___|\__|\__,_| .__/ 
                                               |_|   
BANNER
echo -e "${NC}"
echo -e "  ${BOLD}Cloudflare DDNS 一键配置向导${NC}  (simple-ddns by zcp1997)"
echo -e "  ─────────────────────────────────────────────────────"
echo

# ── Step 1: 路径配置 ───────────────────────────────────────────
title "Step 1 / 5  路径配置"

prompt DDNS_SCRIPT_PATH "ddns.sh 脚本完整路径" "/root/ddns.sh"
prompt CONF_PATH        "配置文件完整路径"     "/root/ddns.conf"
prompt LOG_PATH         "日志文件完整路径"      "/var/log/ddns.log"

check_ddns_script "$DDNS_SCRIPT_PATH"

# ── Step 2: Cloudflare 配置 ────────────────────────────────────
title "Step 2 / 5  Cloudflare API Token"
info  "前往 https://dash.cloudflare.com/profile/api-tokens 创建 Token"
info  "需要权限: Zone - DNS - Edit"
echo

while true; do
    prompt CF_API_TOKEN "CF API Token" "" "true"
    if validate_cf_token "$CF_API_TOKEN"; then
        success "Token 格式看起来合理（${#CF_API_TOKEN} 位）。"
        break
    else
        error "Token 长度过短（至少 20 位），请检查后重新输入。"
    fi
done

# ── Step 3: 域名配置 ───────────────────────────────────────────
title "Step 3 / 5  域名配置"

while true; do
    prompt DOMAIN "主域名 (如 example.com)" ""
    if validate_domain "$DOMAIN"; then
        success "主域名格式正确。"
        break
    else
        error "主域名格式不合法，请输入如 example.com 的格式。"
    fi
done

while true; do
    prompt SUBDOMAIN "子域名 (如 home；根域名请填 @)" ""
    if validate_subdomain "$SUBDOMAIN"; then
        if [[ "$SUBDOMAIN" == "@" ]]; then
            FULL_RECORD="$DOMAIN"
        else
            FULL_RECORD="${SUBDOMAIN}.${DOMAIN}"
        fi
        success "最终 DNS 记录: ${BOLD}${FULL_RECORD}${NC}"
        break
    else
        error "子域名格式不合法（只允许字母、数字、连字符，支持多级如 vpn.home）。"
    fi
done

while true; do
    prompt RECORD_TYPE "记录类型 A=IPv4 / AAAA=IPv6" "A"
    RECORD_TYPE="${RECORD_TYPE^^}"
    if validate_record_type "$RECORD_TYPE"; then
        success "记录类型: $RECORD_TYPE"
        break
    else
        error "只接受 A 或 AAAA，请重新输入。"
    fi
done

# ── Step 4: Telegram 通知（可选）──────────────────────────────
title "Step 4 / 5  Telegram 通知（可选）"
echo -ne "${BOLD}是否启用 Telegram 通知？${NC} [y/N]: "
read -r tg_enable
tg_enable="${tg_enable:-N}"

if [[ "${tg_enable^^}" == "Y" ]]; then
    while true; do
        prompt TELEGRAM_BOT_TOKEN "Bot Token (格式: 123456:ABC-xxx)" "" "true"
        if [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
            success "Bot Token 格式正确。"
            break
        else
            error "Bot Token 格式不合法，应为 数字:字符串 的格式。"
        fi
    done

    while true; do
        prompt TELEGRAM_CHAT_ID "Chat ID (正整数或负整数)" ""
        if [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            success "Chat ID 格式正确。"
            break
        else
            error "Chat ID 应为整数（如 123456789 或群组的 -100xxxxxxx）。"
        fi
    done
else
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    info "已跳过 Telegram 配置。"
fi

prompt SERVER_NAME "服务器标识名称" "My Server"

# ── Step 5: 定时任务 ───────────────────────────────────────────
title "Step 5 / 5  Crontab 定时间隔"

while true; do
    prompt CRON_INTERVAL "检测间隔（分钟，1~60）" "5"
    if validate_cron_interval "$CRON_INTERVAL"; then
        success "将每 ${CRON_INTERVAL} 分钟执行一次检测。"
        break
    else
        error "请输入 1~60 之间的整数。"
    fi
done

# ── 汇总确认 ───────────────────────────────────────────────────
title "确认配置信息"

echo -e "  ${BOLD}脚本路径${NC}       $DDNS_SCRIPT_PATH"
echo -e "  ${BOLD}配置文件${NC}       $CONF_PATH"
echo -e "  ${BOLD}日志文件${NC}       $LOG_PATH"
echo -e "  ${BOLD}CF API Token${NC}   ${CF_API_TOKEN:0:6}***(已隐藏)"
echo -e "  ${BOLD}DNS 记录${NC}       ${FULL_RECORD} (${RECORD_TYPE})"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
echo -e "  ${BOLD}Telegram Bot${NC}   ${TELEGRAM_BOT_TOKEN:0:8}***(已隐藏)"
echo -e "  ${BOLD}Telegram Chat${NC}  $TELEGRAM_CHAT_ID"
else
echo -e "  ${BOLD}Telegram${NC}       未启用"
fi
echo -e "  ${BOLD}服务器名称${NC}     $SERVER_NAME"
echo -e "  ${BOLD}定时间隔${NC}       每 ${CRON_INTERVAL} 分钟"
echo

echo -ne "${BOLD}确认以上信息并继续？${NC} [Y/n]: "
read -r confirm
confirm="${confirm:-Y}"
if [[ "${confirm^^}" != "Y" ]]; then
    warn "已取消，未做任何更改。"
    exit 0
fi

# ── 写入配置文件 ───────────────────────────────────────────────
info "正在写入配置文件 $CONF_PATH ..."

cat > "$CONF_PATH" << EOF
# ── 由 ddns-setup.sh 自动生成 ──────────────────────────────
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# Cloudflare API Token
CF_API_TOKEN="$CF_API_TOKEN"

# 域名配置
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"

# 记录类型：A（IPv4）或 AAAA（IPv6）
RECORD_TYPE="$RECORD_TYPE"

# Telegram Bot Token
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"

# Telegram Chat ID
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"

# 服务器名称（用于 Telegram 通知标识）
SERVER_NAME="$SERVER_NAME"
EOF

chmod 600 "$CONF_PATH"
success "配置文件已写入，权限设为 600。"

# ── 确保日志目录存在 ───────────────────────────────────────────
LOG_DIR="$(dirname "$LOG_PATH")"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ── 检测并安装 cron ────────────────────────────────────────────
ensure_cron() {
    if command -v crontab &>/dev/null; then
        return 0
    fi

    warn "未检测到 crontab 命令，尝试自动安装 cron..."

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        info "检测到 apt，安装 cron ..."
        apt-get update -qq && apt-get install -y -qq cron
    elif command -v apt &>/dev/null; then
        info "检测到 apt，安装 cron ..."
        apt update -qq && apt install -y -qq cron
    elif command -v yum &>/dev/null; then
        info "检测到 yum，安装 cronie ..."
        yum install -y -q cronie
    elif command -v dnf &>/dev/null; then
        info "检测到 dnf，安装 cronie ..."
        dnf install -y -q cronie
    elif command -v apk &>/dev/null; then
        info "检测到 apk（Alpine），安装 dcron ..."
        apk add --quiet dcron
    elif command -v pacman &>/dev/null; then
        info "检测到 pacman（Arch），安装 cronie ..."
        pacman -S --noconfirm --quiet cronie
    else
        error "无法识别的包管理器，请手动安装 cron 后重试。"
        error "常见命令: apt install cron / yum install cronie / apk add dcron"
        exit 1
    fi

    # 安装后再次确认
    if ! command -v crontab &>/dev/null; then
        error "cron 安装后仍未找到 crontab 命令，请手动排查。"
        exit 1
    fi
    success "cron 安装成功。"

    # 启动 cron 服务
    if command -v systemctl &>/dev/null; then
        systemctl enable cron  2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start  cron  2>/dev/null || systemctl start  crond 2>/dev/null || true
        success "cron 服务已启动并设为开机自启。"
    elif command -v service &>/dev/null; then
        service cron start 2>/dev/null || service crond start 2>/dev/null || true
        success "cron 服务已启动。"
    elif command -v rc-service &>/dev/null; then
        # Alpine OpenRC
        rc-service dcron start 2>/dev/null || true
        rc-update add dcron default 2>/dev/null || true
        success "dcron 服务已启动并设为开机自启。"
    else
        warn "无法自动启动 cron 服务，请手动执行: service cron start"
    fi
}

# ── 写入 Crontab ───────────────────────────────────────────────
info "正在配置 crontab ..."
ensure_cron

CRON_LINE="*/$CRON_INTERVAL * * * * $DDNS_SCRIPT_PATH $CONF_PATH >> $LOG_PATH 2>&1"
CRON_MARKER="# ddns-simple-$DOMAIN"

# 移除旧条目（若有），再追加新条目
# crontab -l 无任务时退出码非零，grep -v 无匹配时退出码为1，
# 用 || true 防止 pipefail 误触发退出
{
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true
    echo "$CRON_LINE  $CRON_MARKER"
} | crontab -

success "Crontab 已设置:"
echo -e "  ${YELLOW}$CRON_LINE${NC}"

# ── 立即执行一次 ───────────────────────────────────────────────
title "立即执行 DDNS 检测"
info "运行: $DDNS_SCRIPT_PATH $CONF_PATH"
info "日志同步写入: $LOG_PATH"
echo -e "${YELLOW}─────────────── 输出开始 ───────────────${NC}"
# 同时输出到终端和日志文件（tee -a 追加模式）
{
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') 手动触发 ====="
    bash "$DDNS_SCRIPT_PATH" "$CONF_PATH"
    echo "===== 执行完毕 ====="
} 2>&1 | tee -a "$LOG_PATH"
EXEC_STATUS=${PIPESTATUS[0]}
echo -e "${YELLOW}─────────────── 输出结束 ───────────────${NC}"

if [[ $EXEC_STATUS -eq 0 ]]; then
    success "执行成功！日志已追加至 $LOG_PATH"
else
    warn "脚本退出码: $EXEC_STATUS，请查看上方输出或日志 $LOG_PATH"
fi

echo
echo -e "${BOLD}${GREEN}✓ 所有配置完成！${NC}"
echo -e "  • 日志文件: ${CYAN}$LOG_PATH${NC}"
echo -e "  • 查看 crontab: ${CYAN}crontab -l${NC}"
echo -e "  • 手动触发: ${CYAN}$DDNS_SCRIPT_PATH $CONF_PATH${NC}"
echo
