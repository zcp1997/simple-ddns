#!/bin/bash
set -euo pipefail

CONFIG_FILE="${1:-}"
[ -z "$CONFIG_FILE" ] && echo "使用方法: $0 <配置文件路径>" && exit 1
[ ! -f "$CONFIG_FILE" ] && echo "配置文件不存在: $CONFIG_FILE" && exit 1

# shellcheck disable=SC1090
source "$CONFIG_FILE"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少命令: $1，尝试安装..."
        install_pkg "$1" || {
            echo "无法自动安装命令: $1，请手动安装后重试"
            exit 1
        }
    }
}

install_pkg() {
    if [ -f /etc/debian_version ]; then
        apt update -qq && apt install -y -qq "$1"
    elif [ -f /etc/redhat-release ]; then
        yum install -y "$1"
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install "$1"
    else
        return 1
    fi
}

get_dns_ip() {
    local name="$1"
    local type="$2"

    echo "正在查询DNS记录: $name ($type)" >&2

    if command -v dig >/dev/null 2>&1; then
        local ip
        ip=$(dig +short "$name" "$type" | head -n1 | tr -d '\r')
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过dig获取到DNS IP: $ip" >&2
            echo "$ip"
            return 0
        fi
    fi

    if command -v nslookup >/dev/null 2>&1; then
        local ip=""
        if [ "$type" = "A" ]; then
            ip=$(nslookup "$name" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1 | tr -d '\r')
        else
            ip=$(nslookup -type=AAAA "$name" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1 | tr -d '\r')
        fi
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过nslookup获取到DNS IP: $ip" >&2
            echo "$ip"
            return 0
        fi
    fi

    echo "DNS查询失败，记录可能不存在" >&2
    echo ""
    return 0
}

get_public_ip() {
    # 兼容接口返回 JSON 或纯文本 IP
    local url="$1"
    local curl_family="$2"   # "-4" or "-6"

    local resp=""
    resp="$(curl $curl_family -fsS --max-time 10 "$url" 2>/dev/null || true)"
    resp="$(echo "$resp" | head -n1 | tr -d '\r')"

    local ip=""
    if [ -n "$resp" ] && command -v jq >/dev/null 2>&1 && echo "$resp" | jq -e . >/dev/null 2>&1; then
        ip="$(echo "$resp" | jq -r '.ip // empty' 2>/dev/null || true)"
    else
        ip="$resp"
    fi

    if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
        echo "$ip"
        return 0
    fi

    echo ""
    return 0
}

# 发送消息到 Telegram
send_telegram_message() {
    local message="$1"
    local url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"

    curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg chat_id "$TELEGRAM_CHAT_ID" \
            --arg text "$message" \
            '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')"
}

# 依赖
need_cmd curl
need_cmd jq
# DNS 查询工具可选，至少有一个即可
if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
    echo "缺少 dig/nslookup，尝试安装 dnsutils/bind-utils..."
    if [ -f /etc/debian_version ]; then
        install_pkg dnsutils || true
    elif [ -f /etc/redhat-release ]; then
        install_pkg bind-utils || true
    fi
fi

[ -z "${CF_API_TOKEN:-}" ] && echo "CF_API_TOKEN 未设置" && exit 1
[ -z "${DOMAIN:-}" ] && echo "DOMAIN 未设置" && exit 1
[ -z "${SUBDOMAIN:-}" ] && echo "SUBDOMAIN 未设置" && exit 1
[ -z "${RECORD_TYPE:-}" ] && echo "RECORD_TYPE 未设置" && exit 1
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && echo "TELEGRAM_BOT_TOKEN 未设置" && exit 1
[ -z "${TELEGRAM_CHAT_ID:-}" ] && echo "TELEGRAM_CHAT_ID 未设置" && exit 1
[ -z "${SERVER_NAME:-}" ] && echo "SERVER_NAME 未设置" && exit 1

case "$RECORD_TYPE" in
    A)
        IP_API_URL="ip.sb"
        DNS_TYPE="A"
        CURL_FAMILY="-4"
        ;;
    AAAA)
        IP_API_URL="ip.sb"
        DNS_TYPE="AAAA"
        CURL_FAMILY="-6"
        ;;
    *)
        echo "RECORD_TYPE 必须为 A 或 AAAA"
        exit 1
        ;;
esac

echo "正在获取当前出口IP..."
CURRENT_IP="$(get_public_ip "$IP_API_URL" "$CURL_FAMILY")"
if [[ ! "$CURRENT_IP" =~ ^[0-9a-fA-F\.:]+$ ]]; then
    echo "获取出口 IP 失败（可能无对应协议出口或接口不可达）"
    echo "排错建议："
    echo "  curl $CURL_FAMILY -v --max-time 10 $IP_API_URL"
    exit 1
fi
echo "当前出口IP: $CURRENT_IP"

record_name="$SUBDOMAIN.$DOMAIN"

DNS_IP="$(get_dns_ip "$record_name" "$DNS_TYPE")"

if [ -n "$DNS_IP" ]; then
    if [ "$CURRENT_IP" == "$DNS_IP" ]; then
        echo "出口 IP 与 DNS 一致，无需更新 ($CURRENT_IP)"
        exit 0
    else
        echo "IP不一致，需要更新: DNS=$DNS_IP, 当前=$CURRENT_IP"
    fi
else
    echo "DNS记录不存在或查询失败，将创建新记录"
fi

echo "正在获取Cloudflare Zone ID..."
zone_json="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")"
ZONE_ID="$(echo "$zone_json" | jq -r '.result[0].id // empty')"
[ -z "$ZONE_ID" ] && echo "无法获取 Zone ID（请检查 DOMAIN / Token 权限）" && exit 1
echo "Zone ID: $ZONE_ID"

echo "正在查询现有DNS记录..."
record_json="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$RECORD_TYPE" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")"
RECORD_ID="$(echo "$record_json" | jq -r '.result[0].id // empty')"

payload="$(jq -nc --arg type "$RECORD_TYPE" --arg name "$record_name" --arg content "$CURRENT_IP" \
    '{type:$type,name:$name,content:$content,ttl:600,proxied:false}')"

if [ -z "$RECORD_ID" ]; then
    echo "记录不存在，创建中..."
    response="$(curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "$payload")"
else
    echo "记录存在，Record ID: $RECORD_ID，更新中..."
    response="$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "$payload")"
fi

if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "更新成功: $record_name -> $CURRENT_IP"
    MSG="✅ *更新成功*
🖥 *服务器:* ${SERVER_NAME}
🌐 *域名:* \`${record_name}\`
📤 *旧IP:* \`${DNS_IP:-未知}\`
📥 *新IP:* \`${CURRENT_IP}\`"
    send_telegram_message "$MSG"
else
    echo "更新失败："
    ERR="$(echo "$response" | jq -r '.errors[0].message // "未知错误"')"
    MSG="❌ *更新失败*
🖥 *服务器:* ${SERVER_NAME}
🌐 *域名:* \`${record_name}\`
⚠️ *错误:* ${ERR}"
    send_telegram_message "$MSG"
    echo "$response" | jq . || echo "$response"
    exit 1
fi
