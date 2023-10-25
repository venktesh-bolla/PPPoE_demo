#!/bin/bash

if [ `whoami` != 'root' ]; then
	echo "Must execute this script as root"
	exit 1
fi

## initial setup
apt-get install pppoe pppoeconf -y 2>>/dev/null 1>>/dev/null

## create namespaces
ppp_server_ns="ISP_wan"
ppp_server_iface="wan_veth0"
ppp_client_ns="DUT_router"
ppp_client_iface="gw_veth1"

## client has to use these credentials to connect with ppp server
ppp_client_username="test01"
ppp_client_passwd="pass01"
ppp_client_ip="10.0.0.10"
ppp_server_ip="10.0.0.1"
ppp_server_log_file="/var/log/pppd.log"

init () {
ip netns add $ppp_server_ns
ip netns add $ppp_client_ns
# create veth pair and connect them back to back
ip link add $ppp_server_iface type veth peer name $ppp_client_iface
# assign one iface to server
ip link set $ppp_server_iface netns $ppp_server_ns
ip netns exec $ppp_server_ns ip link set $ppp_server_iface up
# assign one iface to client
ip link set $ppp_client_iface netns $ppp_client_ns
ip netns exec $ppp_client_ns ip link set $ppp_client_iface up
#ip netns exec wan ip a add 203.0.113.1/24 dev wan-veth0

## config pppoe server options(works for wan namespace)
cat > /etc/ppp/pppoe-server-options << EOF
require-chap
lcp-echo-interval 60 
lcp-echo-failure 5
debug
logfile $ppp_server_log_file
EOF

## create pppoe client credentials in the server config file
echo "\"$ppp_client_username\" * \"$ppp_client_passwd\" $ppp_client_ip" > /etc/ppp/chap-secrets

## start pppoe-server on wan namespace, with local ip as $ppp_server_ip
ip netns exec $ppp_server_ns pppoe-server -I $ppp_server_iface -L $ppp_server_ip

## client settings
while true; do
	echo ""
	cat << EOF
Please select below options for config menu:
--------------------------------------------
OKAY to MODIFY       : yes
POPULAR OPTIONS      : no
ENTER USERNAME       : $ppp_client_username
ENTER PASSWORD       : $ppp_client_passwd
USE PEER DNS         : yes
LIMTED MSS PROBLEM   : yes
DONE                 : no
ESTABLISH CONNECTION : no
EOF

	echo ""
	read -p "Do you understand [Y/y]:" -n 1 -r
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		echo ""
		break
	fi
done

ip netns exec $ppp_client_ns pppoeconf $ppp_client_iface
# above client config overwrites chap-secrets as we are in namespace not full-fledged systems
echo "\"$ppp_client_username\" * \"$ppp_client_passwd\" $ppp_client_ip" > /etc/ppp/chap-secrets
# above config line, creates some junk interface in the /etc/ppp/peers/dsl-provider
correct_iface_line="nic-$ppp_client_iface"
sed -i "/nic-/d" /etc/ppp/peers/dsl-provider
echo "$correct_iface_line" >> /etc/ppp/peers/dsl-provider

## client initiate connection
ip netns exec $ppp_client_ns pon dsl-provider
}

clean () {
## client stop the connection
ip netns exec $ppp_client_ns poff -a

# destroy the namespaces
ip netns exec $ppp_server_ns ip link set $ppp_server_iface down
ip netns exec $ppp_server_ns ip link set $ppp_server_iface netns 1
ip netns exec $ppp_client_ns ip link set $ppp_client_iface down
ip netns exec $ppp_client_ns ip link set $ppp_client_iface netns 1
ifconfig -a $ppp_server_iface 2>>/dev/null 1>>/dev/null
[[ $? -eq 0 ]] && ip link delete $ppp_server_iface
ifconfig -a $ppp_client_iface 2>>/dev/null 1>>/dev/null
[[ $? -eq 0 ]] && ip link delete $ppp_client_iface
ip netns delete $ppp_server_ns
ip netns delete $ppp_client_ns
}

init
#clean
