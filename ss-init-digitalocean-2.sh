#!/bin/bash

# 设置脚本遇到错误时立即退出
set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查环境变量
if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
    log "Error: SLACK_WEBHOOK_URL is not set"
    exit 1
fi
if [[ -z "$DINGTALK_WEBHOOK_URL" ]]; then
    log "Warn: DINGTALK_WEBHOOK_URL is not set"
fi
if [[ -z "$SSPASSWD" ]]; then
    log "Error: SSPASSWD is not set"
    exit 1
fi

# 设置时区（可选）
if command_exists timedatectl; then
    timedatectl set-timezone Asia/Shanghai
    log "Timezone set to Asia/Shanghai"
else
    log "Warning: timedatectl not found, skipping timezone setup"
fi

# 停止防火墙（可选）
if command_exists systemctl; then
    systemctl stop firewalld || log "Warning: Failed to stop firewalld"
else
    log "Warning: systemctl not found, skipping firewall stop"
fi

# 安装 Python 和 Shadowsocks
log "Installing python3 and shadowsocks..."
if command_exists dnf; then
    # 清理dnf缓存
    dnf clean all || log "Warning: Failed to clean dnf cache"
    # 安装必要的包，包括 openssl-libs (dnf会自动处理openssl依赖)
    dnf install -y python3 python3-pip openssl openssl-libs yum-utils || \
    { log "Error: Failed to install python3, python3-pip, openssl, openssl-libs, or yum-utils"; exit 1; }
elif command_exists apt; then
    # 如果是 Debian/Ubuntu 系统，虽然你目前使用的是 dnf，但为了兼容性可以保留
    apt update -y
    apt install -y python3 python3-pip openssl libssl-dev debian-goodies || \
    { log "Error: Failed to install python3, python3-pip, openssl, libssl-dev, or debian-goodies"; exit 1; }
else
    log "Error: No supported package manager (dnf or apt) found, cannot install packages"
    exit 1
fi

if command_exists pip3; then
    pip3 install --no-cache-dir shadowsocks || { log "Error: Failed to install shadowsocks"; exit 1; }
else
    log "Error: pip3 not found after package installation"
    exit 1
fi

log "### Install section completed ###"

# 获取 Shadowsocks 的 site-packages 路径
site_packages=$(pip3 show shadowsocks 2>/dev/null | grep -i "Location:" | awk '{print $2}')
if [[ -z "$site_packages" || ! -d "$site_packages" ]]; then
    log "Error: Could not determine site-packages path for Shadowsocks"
    exit 1
fi
log "Using site-packages: $site_packages"

# 更新 lru_cache.py
lru_cache_file="$site_packages/shadowsocks/lru_cache.py"

if [[ ! -f "$lru_cache_file" ]]; then
    log "Error: File $lru_cache_file does not exist."
    exit 1
fi

# Check if patch already applied
if grep -q "from collections.abc import MutableMapping" "$lru_cache_file"; then
    log "Modification already exists in $lru_cache_file."
else
    # Insert compatibility imports after "import collections"
    sed -i '/import collections/a\
import sys\
if sys.version_info >= (3, 10):\
    from collections.abc import MutableMapping\
else:\
    from collections import MutableMapping' "$lru_cache_file"

    # Replace "collections.MutableMapping" with just "MutableMapping"
    sed -i 's/collections\.MutableMapping/MutableMapping/g' "$lru_cache_file"

    log "Modification added to $lru_cache_file successfully."
fi

# 检查 OpenSSL 版本并更新 openssl.py
if command_exists openssl; then
    openssl_version=$(openssl version 2>/dev/null | awk '{print $2}')
    openssl_major=$(echo "$openssl_version" | cut -d '.' -f1)
    openssl_minor=$(echo "$openssl_version" | cut -d '.' -f2)

    if [[ "$openssl_major" -gt 1 || ( "$openssl_major" -eq 1 && "$openssl_minor" -ge 1 ) ]]; then
        log "OpenSSL version is $openssl_version (>= 1.1.x), updating openssl.py..."
        openssl_py_file="$site_packages/shadowsocks/crypto/openssl.py"

        if [[ -f "$openssl_py_file" ]]; then
            sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' "$openssl_py_file" && \
                log "Replaced EVP_CIPHER_CTX_cleanup in $openssl_py_file" || \
                log "Error: Failed to modify $openssl_py_file"
        else
            log "Error: $openssl_py_file does not exist"
        fi
    else
        log "OpenSSL version is $openssl_version (< 1.1.x), no changes made"
    fi
else
    log "Warning: OpenSSL not found, skipping OpenSSL modifications"
fi

log "### Fix code section completed ###"

# 获取服务器 IP，设置 5 秒超时
server_ip=$(curl -s --connect-timeout 5 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null)
exit_code=$?

# 检查退出状态码和变量是否为空
if [[ $exit_code -ne 0 || -z "$server_ip" ]]; then
    log "Failed to get server IP (exit code: $exit_code), using default: 0.0.0.0"
    server_ip="0.0.0.0"
else
    log "Server IP retrieved: $server_ip"
fi

cat << EOF > /etc/shadowsocks.json
{
    "server": "$server_ip",
    "server_port": 9094,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "$SSPASSWD",
    "timeout": 300,
    "method": "aes-256-cfb",
    "fast_open": false
}
EOF

# 设置 TCP 拥塞控制算法为 BBR
log "Setting TCP congestion control to BBR"
modprobe tcp_bbr || log "Warning: Failed to load tcp_bbr module"
sysctl -w net.ipv4.tcp_congestion_control=bbr || log "Error: Failed to set BBR as TCP congestion control"
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf || log "Warning: Failed to persist BBR setting"
sysctl -p # 加载 sysctl 配置

# 启动 Shadowsocks 服务
ssserver -c /etc/shadowsocks.json -d start
sleep 2
testing=$(head -2 /var/log/shadowsocks.log)

# 发送 Slack 通知
generate_slack_post_data()
{
cat << EOF
{
    "channel": "#monitoring-infrastructure",
    "icon_emoji": ":ghost:",
    "username": "ss-notice-digitalocean",
    "blocks": [{"type": "section", "text":{"type": "mrkdwn", "text":"$testing"}}]
}
EOF
}
curl -s -i -H "Accept: application/json" -H "Content-type: application/json" --data "$(generate_slack_post_data)" -X POST "${SLACK_WEBHOOK_URL}"
echo # 确保日志消息换行

# 发送 DingTalk 通知 (如果 DINGTALK_WEBHOOK_URL 已设置)
if [[ -n "$DINGTALK_WEBHOOK_URL" ]]; then
    log "send a message to dingtalk"
    generate_dingtalk_post_data()
    {
    local message_content="ss-notice: ${testing}" # 确保消息内容中包含关键词
    cat << EOF
{
    "msgtype": "text",
    "text": {
        "content": "${message_content}"
    }
}
EOF
    }
    curl -s -i -H "Accept: application/json" -H "Content-type: application/json" --data "$(generate_dingtalk_post_data)" -X POST "${DINGTALK_WEBHOOK_URL}"
    echo # 确保日志消息换行
fi

# ====================================================================
# 新增部分：重启服务以应用库更新
# ====================================================================

log "Checking for services that require restarting due to library updates..."

# 优先重启 sshd
if command_exists systemctl; then
    log "Attempting to restart sshd service first..."
    systemctl restart sshd &>/dev/null || log "Warning: Failed to restart sshd service immediately."
    # 注意：这里我们立即尝试重启 sshd，但不对其失败进行硬性退出，
    # 因为在 cloud-init 脚本中，如果当前会话因此断开，脚本会继续执行。
    # 如果 sshd 真的无法启动，后续的 ssh 尝试仍然会失败。
    # 这里使用 &>/dev/null 隐藏输出，因为在 cloud-init 中这些输出可能被视为错误。
fi

# 识别其他需要重启的服务并尝试重启它们
if command_exists needs-restarting; then
    # 排除ssh服务本身，因为我们已经处理过
    services_to_restart=$(needs-restarting -s | grep -v "sshd")

    if [[ -n "$services_to_restart" ]]; then
        log "Found services requiring restart: $services_to_restart"
        for service in $services_to_restart; do
            if systemctl is-active --quiet "$service"; then
                log "Restarting service: $service"
                systemctl restart "$service" &>/dev/null || log "Warning: Failed to restart $service."
            else
                log "Service $service is not active, skipping restart."
            fi
        done
    else
        log "No other services requiring restart found."
    fi
else
    log "Warning: 'needs-restarting' not found. Cannot automatically identify and restart services."
    log "Please ensure all necessary services (especially sshd) are restarted manually if this is a concern."
fi

# ====================================================================
# 新增部分结束
# ====================================================================


# 创建测试文件
log "Creating a 150MB test file for disk&network I/O testing"
dd if=/dev/zero of=/root/loopdev bs=1M count=150 2>/dev/null || log "Warning: Failed to create test file"

log "Script completed successfully"
exit 0
