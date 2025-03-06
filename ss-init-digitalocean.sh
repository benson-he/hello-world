#!/bin/bash

timedatectl set-timezone Asia/Shanghai
systemctl stop firewalld
sleep 1
# 1
yum install python3 python3-pip -y 
pip3 install shadowsocks
echo -e "\n######\n"
# Get OpenSSL version
openssl_version=$(openssl version | awk '{print $2}')
openssl_major=$(echo $openssl_version | cut -d '.' -f 1)
openssl_minor=$(echo $openssl_version | cut -d '.' -f 2)

# Get Python version (f2: major and minor version)
my_python_version_f2=$(python3 -V | awk '{print $2}' | cut -d '.' -f -2)

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

# Check if Python version is 3.10.x or later
python_version=$(python3 --version 2>&1 | awk '{print $2}')
python_major=$(echo $python_version | cut -d. -f1)
python_minor=$(echo $python_version | cut -d. -f2)

if [ "$python_major" -ge 3 ] && [ "$python_minor" -ge 10 ]; then
    echo "Python version is 3.10.x or later, proceeding with update..."
    lru_cache_py_file="/usr/local/lib/python${my_python_version_f2}/site-packages/shadowsocks/lru_cache.py"
    
    # Check if file exists before making changes
    if [[ -f "$lru_cache_py_file" ]]; then
        sed -i 's#collections.MutableMapping#collections.abc.MutableMapping#g' "$lru_cache_py_file"
        echo "Replaced collections.MutableMapping with collections.abc.MutableMapping in $lru_cache_py_file"
    else
        echo "Error: File $lru_cache_py_file does not exist."
    fi
else
    echo "Python version is 3.10.x or later. No changes made."
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
echo -e "\n######\n"
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
echo -e "\n######\n"
dd if=/dev/zero of=/root/loopdev bs=1M count=150
echo -e "\n"
