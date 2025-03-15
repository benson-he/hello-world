#!/bin/bash

# 设置脚本退出时遇到错误
set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

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
dnf install -y python3 python3-pip || {
    log "Error: Failed to install python3 and python3-pip"
    exit 1
}
pip3 install shadowsocks || {
    log "Error: Failed to install shadowsocks"
    exit 1
}
log "### Install section completed ###"

# 获取 Shadowsocks 的 site-packages 路径
site_packages=$(pip3 show shadowsocks 2>/dev/null | grep -i "Location:" | awk '{print $2}')
if [[ -z "$site_packages" || ! -d "$site_packages" ]]; then
    log "Error: Could not determine site-packages path for Shadowsocks"
    exit 1
fi
log "Using site-packages: $site_packages"

# 检查 Python 版本并更新 lru_cache.py
python_version=$(python3 --version 2>&1 | awk '{print $2}')
python_major=${python_version%%.*}
python_minor=${python_version#*.}
python_minor=${python_minor%%.*}

if [[ "$python_major" -ge 3 && "$python_minor" -ge 10 ]]; then
    log "Python version is $python_version (>= 3.10), updating lru_cache.py..."
    lru_cache_py_file="$site_packages/shadowsocks/lru_cache.py"
    if [[ -f "$lru_cache_py_file" ]]; then
        sed -i 's#collections\.MutableMapping#collections.abc.MutableMapping#g' "$lru_cache_py_file" && \
            log "Replaced collections.MutableMapping in $lru_cache_py_file" || \
            log "Error: Failed to modify $lru_cache_py_file"
    else
        log "Error: $lru_cache_py_file does not exist"
    fi
else
    log "Python version is $python_version (< 3.10), no changes made"
fi

# 检查 OpenSSL 版本并更新 openssl.py
openssl_version=$(openssl version 2>/dev/null | awk '{print $2}')
openssl_major=$(echo "$openssl_version" | cut -d '.' -f 1)
openssl_minor=$(echo "$openssl_version" | cut -d '.' -f 2)

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

log "### Fix code section completed ###"

# 2
server_ip=`curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address`
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

# 3
ssserver -c /etc/shadowsocks.json -d start
# 4
sleep 2
testing=$(head -2 /var/log/shadowsocks.log)

generate_post_data()
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
curl -s -i -H "Accept: application/json" -H "Content-type: application/json" --data "$(generate_post_data)" -X POST ${SLACK_WEBHOOK_URL}
echo -e "\n######"
dd if=/dev/zero of=/root/loopdev bs=1M count=150
log "Script completed successfully"
exit 0
