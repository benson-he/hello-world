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
pip3 install shadowsocks
echo "######"
# 3
server_ip=`ip addr | grep inet | egrep -v 'inet6|127' | awk '{print $2}' | awk -F "/" '{print $1}'`

cat << EOF > /etc/shadowsocks.json 
{
    "server": "$server_ip",
    "server_port": 9094,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "MySsPass4!",
    "timeout": 300,
    "method": "aes-256-cfb",
    "fast_open": false
}
EOF
echo "######"
# 4
ssserver -c /etc/shadowsocks.json -d start
