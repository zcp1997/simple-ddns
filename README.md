# DDNS 自动更新脚本

自动检测服务器出口 IP，与 Cloudflare DNS 记录对比，如有变化则自动更新，并通过 Telegram Bot 发送通知。

## 功能特性

- 支持 IPv4（A 记录）和 IPv6（AAAA 记录）
- 自动创建或更新 Cloudflare DNS 记录
- IP 变化时通过 Telegram Bot 实时通知
- 自动安装缺失依赖（支持 Debian / Ubuntu / OpenWrt）

## 依赖

| 工具 | 说明 |
|------|------|
| `curl` | HTTP 请求 |
| `jq` | JSON 解析 |
| `dig` 或 `nslookup` | DNS 查询（二选一即可）|

脚本会在运行时自动尝试安装缺失依赖。

## 使用方法

### 1. 下载脚本
```bash
wget -O ddns.sh https://raw.githubusercontent.com/zcp1997/simple-ddns/main/ddns.sh
chmod +x ddns.sh
```

### 2. 创建配置文件
```bash
vim ddns.conf
```

配置文件内容如下：
```bash
# Cloudflare API Token
CF_API_TOKEN="YOUR_TOKEN"

# 域名配置
DOMAIN="example.com"   # 主域名
SUBDOMAIN="ex"         # 子域名，最终记录为 ex.example.com

# 记录类型：A（IPv4）或 AAAA（IPv6）
RECORD_TYPE="A"

# Telegram Bot Token
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"

# Telegram Chat ID
TELEGRAM_CHAT_ID="YOUR_CHATID"

# 服务器名称（用于 Telegram 通知标识）
SERVER_NAME="My Server"
```

### 3. 手动运行
```bash
./ddns.sh ddns.conf
```

### 4. 设置定时任务
```bash
crontab -e
```

每 5 分钟检测一次：
```
*/5 * * * * /root/ddns.sh /root/ddns.conf >> /var/log/ddns.log 2>&1
```

## Telegram 通知示例

**检测到 IP 变化时：**
```
🔄 检测到 IP 变化
🖥 服务器: My Server
🌐 域名: ex.example.com
📤 旧IP: 1.2.3.4
📥 新IP: 5.6.7.8
```

**更新成功时：**
```
✅ 更新成功
🖥 服务器: My Server
🌐 域名: ex.example.com
📤 旧IP: 1.2.3.4
📥 新IP: 5.6.7.8
```

**更新失败时：**
```
❌ 更新失败
🖥 服务器: My Server
🌐 域名: ex.example.com
⚠️ 错误: Invalid API token
```

## 如何获取配置参数

**Cloudflare API Token**
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com)
2. 进入 `我的个人资料` → `API 令牌` → `创建令牌`
3. 使用 `编辑区域 DNS` 模板，选择对应域名

**Telegram Bot Token**
1. 在 Telegram 中找到 [@BotFather](https://t.me/BotFather)
2. 发送 `/newbot` 创建机器人，获取 Token

**Telegram Chat ID**
1. 找到 [@userinfobot](https://t.me/userinfobot)
2. 发送任意消息即可获取你的 Chat ID
