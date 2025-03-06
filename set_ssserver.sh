#!/bin/bash

if [[ $1 =~ -h|--help ]];then
cat <<EOF
Usage: $0 ports(separate by blank, default value: "22 80 443")
Example:
    $0 22 80 443
EOF
    exit 0
fi
# 1
systemctl stop firewalld
echo "######"
# 2
yum install python3 python3-pip -y
pip3 install shadowsocks
echo "######"
my_python_version=`python -V | awk '{print $2}'`
my_python_version_2digit=${my_python_version:0:3}
sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' /usr/local/lib/python${my_python_version_2digit}/site-packages/shadowsocks/crypto/openssl.py
# 3
server_ip=`ip addr | grep inet | egrep -v 'inet6|127' | awk '{print $2}' | awk -F "/" '{print $1}'`

cat << EOF > /etc/shadowsocks.json 
{
    "server": "$server_ip",
    "server_port": 9094,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "$SS_PASSWORD",
    "timeout": 300,
    "method": "aes-256-cfb",
    "fast_open": false
}
EOF
echo "######"
# 4
ssserver -c /etc/shadowsocks.json -d start
# 5
testing=$(head -2 /var/log/shadowsocks.log)
#echo -e $testing

generate_post_data()
{
cat <<EOF
{
        "channel": "#monitoring-infrastructure",
        "icon_emoji": ":ghost:",
        "username": "ss-notice",
        "blocks":[{"type":"section","text":{"type":"mrkdwn","text":"*_fancy meassages:_*$testing"}}]
}
EOF
}

curl -i -H "Accept: application/json" -H "Content-type: application/json" \
--data "$(generate_post_data)" -X POST https://hooks.slack.com/services/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

dd if=/dev/zero of=/root/loopdev bs=1M count=100
