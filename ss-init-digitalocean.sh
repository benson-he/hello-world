#!/bin/bash

timedatectl set-timezone Asia/Shanghai
systemctl stop firewalld
sleep 1
# 1
yum install python3 python3-pip -y 
pip3 install shadowsocks
echo -e "###Install finished###"
# Get OpenSSL version
openssl_version=$(openssl version | awk '{print $2}')
openssl_major=$(echo $openssl_version | cut -d '.' -f 1)
openssl_minor=$(echo $openssl_version | cut -d '.' -f 2)

# Check if OpenSSL version is 1.1.x or later
if [[ "$openssl_major" -gt 1 || ( "$openssl_major" -eq 1 && "$openssl_minor" -ge 1 ) ]]; then
    echo "OpenSSL version is 1.1.x or later, proceeding with update..."
    openssl_py_file="/usr/local/lib/python${my_python_version_f2}/site-packages/shadowsocks/crypto/openssl.py"    
    # Check if file exists before making changes
    if [[ -f "$openssl_py_file" ]]; then
        sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' "$openssl_py_file"
        echo "Replaced EVP_CIPHER_CTX_cleanup with EVP_CIPHER_CTX_reset in $openssl_py_file"
    else
        echo "Error: File $openssl_py_file does not exist."
    fi
else
    echo "OpenSSL version is older than 1.1.x ($openssl_version). No changes made."
fi

# 检查 Python 版本是否 >= 3.10，并更新 shadowsocks 的 lru_cache.py 文件

# 获取 Python 版本，处理可能的错误输出
python_version=$(python3 --version 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to get Python version. Is python3 installed?"
    exit 1
fi

# 提取主版本号和次版本号，使用更简洁的方式
python_version=$(echo "$python_version" | awk '{print $2}')
python_major=${python_version%%.*}  # 提取主版本（如 3）
python_minor=${python_version#*.}   # 提取次版本和补丁（如 13.2）
python_minor=${python_minor%%.*}    # 提取次版本（如 13）

# 检查是否 >= 3.10
if [[ "$python_major" -ge 3 && "$python_minor" -ge 10 ]]; then
    echo "Python version is $python_version (>= 3.10), proceeding with update..."

    # 动态获取 site-packages 路径，避免硬编码
    python_ver="$python_major.$python_minor"  # 如 3.13
    site_packages=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
    if [[ -z "$site_packages" ]]; then
        echo "Warning: Could not determine site-packages path, falling back to /usr/local/lib/python$python_ver/site-packages"
        site_packages="/usr/local/lib/python$python_ver/site-packages"
    fi
    lru_cache_py_file="$site_packages/shadowsocks/lru_cache.py"

    # 检查文件是否存在
    if [[ -f "$lru_cache_py_file" ]]; then
        # 检查文件是否可写
        if [[ ! -w "$lru_cache_py_file" ]]; then
            echo "Error: No write permission for $lru_cache_py_file. Try running with sudo."
            exit 1
        fi

        # 执行替换并检查是否成功
        sed -i 's#collections\.MutableMapping#collections.abc.MutableMapping#g' "$lru_cache_py_file"
        if [[ $? -eq 0 ]]; then
            echo "Replaced collections.MutableMapping with collections.abc.MutableMapping in $lru_cache_py_file"
        else
            echo "Error: Failed to modify $lru_cache_py_file"
            exit 1
        fi
    else
        echo "Error: File $lru_cache_py_file does not exist. Is shadowsocks installed?"
        exit 1
    fi
else
    echo "Python version is $python_version (< 3.10). No changes made."
    exit 0
fi

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
