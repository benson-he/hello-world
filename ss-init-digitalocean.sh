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
log "### Install finished ###"

# 获取 Python 版本
python_version=$(python3 --version 2>&1) || {
    log "Error: Failed to get Python version. Is python3 installed?"
    exit 1
}
python_version=$(echo "$python_version" | awk '{print $2}')
python_major=${python_version%%.*}
python_minor=${python_version#*.}
python_minor=${python_minor%%.*}
python_ver="$python_major.$python_minor"

# 动态获取 site-packages 路径
site_packages=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
if [[ -z "$site_packages" ]]; then
    log "Warning: Could not determine site-packages path, falling back to /usr/local/lib/python$python_ver/site-packages"
    site_packages="/usr/local/lib/python$python_ver/site-packages"
fi

# 检查并更新 OpenSSL 相关文件
openssl_version=$(openssl version 2>/dev/null | awk '{print $2}') || {
    log "Error: Failed to get OpenSSL version. Is openssl installed?"
    exit 1
}
openssl_major=$(echo "$openssl_version" | cut -d '.' -f 1)
openssl_minor=$(echo "$openssl_version" | cut -d '.' -f 2)

if [[ "$openssl_major" -gt 1 || ( "$openssl_major" -eq 1 && "$openssl_minor" -ge 1 ) ]]; then
    log "OpenSSL version is $openssl_version (>= 1.1.x), proceeding with update..."
    openssl_py_file="$site_packages/shadowsocks/crypto/openssl.py"
    if [[ -f "$openssl_py_file" ]]; then
        if [[ ! -w "$openssl_py_file" ]]; then
            log "Error: No write permission for $openssl_py_file. Try running with sudo."
            exit 1
        fi
        sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' "$openssl_py_file" && \
            log "Replaced EVP_CIPHER_CTX_cleanup with EVP_CIPHER_CTX_reset in $openssl_py_file" || \
            log "Error: Failed to modify $openssl_py_file"
    else
        log "Error: File $openssl_py_file does not exist."
    fi
else
    log "OpenSSL version is $openssl_version (< 1.1.x). No changes made."
fi

# 检查并更新 Python 相关文件
if [[ "$python_major" -ge 3 && "$python_minor" -ge 10 ]]; then
    log "Python version is $python_version (>= 3.10), proceeding with update..."
    lru_cache_py_file="$site_packages/shadowsocks/lru_cache.py"
    if [[ -f "$lru_cache_py_file" ]]; then
        if [[ ! -w "$lru_cache_py_file" ]]; then
            log "Error: No write permission for $lru_cache_py_file. Try running with sudo."
            exit 1
        fi
        sed -i 's#collections\.MutableMapping#collections.abc.MutableMapping#g' "$lru_cache_py_file" && \
            log "Replaced collections.MutableMapping with collections.abc.MutableMapping in $lru_cache_py_file" || \
            log "Error: Failed to modify $lru_cache_py_file"
    else
        log "Error: File $lru_cache_py_file does not exist. Is shadowsocks installed?"
    fi
else
    log "Python version is $python_version (< 3.10). No changes made."
fi

log "Script completed successfully"
exit 0

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
#echo -e $testing
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
