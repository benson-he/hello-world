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
log "Installing python3, pip and other utilities..."
if command_exists dnf; then
    # 清理dnf缓存
    dnf clean all || log "Warning: Failed to clean dnf cache"
    # 安装必要的包，包括 openssl-libs (dnf会自动处理openssl依赖)
    # yum-utils 确保在此处安装，以便后续的 needs-restarting 使用
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
    # Extract major and minor versions. OpenSSL 3.x.y means major=3, minor=x
    openssl_major=$(echo "$openssl_version" | cut -d '.' -f1)
    openssl_minor=$(echo "$openssl_version" | cut -d '.' -f2)

    # Simplified check for OpenSSL 1.1.x and later (including 3.x.x)
    # The fix is generally for 1.1.0+ where EVP_CIPHER_CTX_cleanup was replaced.
    # OpenSSL 3.x versions would fall into this >= 1.1 category.
    if [[ "$openssl_major" -gt 1 || ( "$openssl_major" -eq 1 && "$openssl_minor" -ge 1 ) ]]; then
        log "OpenSSL version is $openssl_version (>= 1.1.x), updating openssl.py..."
        openssl_py_file="$site_packages/shadowsocks/crypto/openssl.py"

        if [[ -f "$openssl_py_file" ]]; then
            # Ensure sed handles potential multiple lines or first occurrence.
            # Use 's/pattern/replacement/g' for global replacement on a line.
            # Using '\&' to match and replace the found string safely.
            sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' "$openssl_py_file" && \
                log "Replaced EVP_CIPHER_CTX_cleanup with EVP_CIPHER_CTX_reset in $openssl_py_file" || \
                log "Error: Failed to modify $openssl_py_file"
        else
            log "Error: $openssl_py_file does not exist"
        fi
    else
        log "OpenSSL version is $openssl_version (< 1.1.x), no changes made to openssl.py"
    fi
else
    log "Warning: OpenSSL not found, skipping OpenSSL modifications for Shadowsocks."
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
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf || log "Warning: Failed to persist BBR setting to /etc/sysctl.conf"
sysctl -p # 加载 sysctl 配置

# 启动 Shadowsocks 服务
log "Starting Shadowsocks server..."
ssserver -c /etc/shadowsocks.json -d start
sleep 2
testing=$(head -2 /var/log/shadowsocks.log)

# 发送 Slack 通知
log "Sending Slack notification..."
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
    log "Sending DingTalk notification..."
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
# 新增部分：确保 SSH 正常工作 (移动到此处)
# ====================================================================

log "Ensuring OpenSSH server is correctly installed and configured..."

if command_exists dnf; then
    # 尝试重新安装 openssh-server 和 openssh-clients
    # 如果 dnf reinstall 失败 (例如因为 'from anaconda' 导致的包不可用), 则尝试 remove 再 install
    if ! dnf reinstall -y openssh-server openssh-clients; then
        log "dnf reinstall failed, attempting to remove and then install openssh-server and openssh-clients..."
        log "!!! WARNING: SSH access may be temporarily interrupted during this process. !!!"
        dnf remove -y openssh-server openssh-clients || { log "Error: Failed to remove OpenSSH packages."; exit 1; }
        dnf install -y openssh-server openssh-clients || { log "Error: Failed to install OpenSSH packages."; exit 1; }
        log "OpenSSH packages reinstalled."
    else
        log "OpenSSH packages reinstalled successfully with dnf reinstall."
    fi

    # 确保 sshd 服务启动
    systemctl enable sshd --now || log "Warning: Failed to enable and start sshd service."
    log "sshd service status after initial setup:"
    systemctl status sshd || true # true ensures script doesn't exit if status command itself fails
    sshd -t || log "Warning: sshd configuration test failed after reinstallation."

else
    log "Warning: No dnf found. OpenSSH check and reinstallation skipped."
fi

log "### OpenSSH setup completed ###"

# ====================================================================
# 新增部分结束
# ====================================================================

# ====================================================================
# 修正部分：重启服务以应用库更新 (主要针对非 SSH 服务)
# ====================================================================

log "Checking for other services that require restarting due to library updates..."

# 'yum-utils' (or 'dnf-utils') for 'needs-restarting' should be installed by now
if command_exists needs-restarting; then
    # 排除sshd服务，因为它在脚本开始时已经被重点处理过
    services_to_restart=$(needs-restarting -s | grep -v "sshd" || true) # '|| true' prevents exiting if grep finds nothing

    if [[ -n "$services_to_restart" ]]; then
        log "Found other services requiring restart: $services_to_restart"
        for service in $services_to_restart; do
            if systemctl is-active --quiet "$service"; then
                log "Restarting service: $service"
                systemctl restart "$service" &>/dev/null || log "Warning: Failed to restart $service."
            else
                log "Service "$service" is not active, skipping restart."
            fi
        done
    else
        log "No other services explicitly requiring restart found."
    fi
else
    log "Warning: 'needs-restarting' not found. Cannot automatically identify and restart other services."
    log "Please ensure all necessary services are restarted manually if this is a concern."
fi

# ====================================================================
# 修正部分结束
# ====================================================================

# 创建测试文件
log "Creating a 150MB test file for disk & network I/O testing"
dd if=/dev/zero of=/root/loopdev bs=1M count=150 2>/dev/null || log "Warning: Failed to create test file"

log "Script completed successfully"
exit 0
