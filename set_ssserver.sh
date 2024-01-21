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

# 2
pip3 install shadowsocks

# 3
yum install net-tools -y
server_ip=`ifconfig | grep inet | egrep -v 'inet6|127' | awk '{print $2}'`

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
# 4
ssserver -c /etc/shadowsocks.json -d start
