#!/bin/bash

if [ `whoami` != 'root' ]; then
	echo "Must execute this script as root"
	exit 1
fi

## initial setup
apt-get install pppoe pppoeconf -y 2>>/dev/null 1>>/dev/null

## create namespaces and ifaces
facebook_server_ns="facebook"
facebook_server_iface="fb_veth0"
facebook_server_ip=157.240.235.35
gmail_server_ns="gmail"
gmail_server_iface="gm_veth0"
gmail_server_ip=153.120.200.53

ISP_ppp_server_ns="ISP_wan_provider"
ISP_WAN_ppp_server_iface="wan_veth0"
ISP_facebook_server_iface="wan_veth1"
ISP_facebook_server_iface_ip=157.240.235.36
ISP_gmail_server_iface="wan_veth2"
ISP_gmail_server_iface_ip=153.120.200.54

router_ppp_client_ns="DUT_router"
router_WAN_ppp_client_iface="gw_veth0"
router_LAN_iface1="gw_veth1"
router_LAN_iface2="gw_veth2"
router_LAN_iface3="gw_veth3"
router_LAN_iface4="gw_veth4"
router_LAN_bridge_name="br-lan"
router_LAN_bridge_ip=11.0.0.1  #router Private IP
router_private_ip=$router_LAN_bridge_ip

PC1_ns="LAN_pc1"
PC1_LAN_iface="pc1_veth0"
PC1_LAN_iface_ip=11.0.0.2

PC2_ns="LAN_pc2"
PC2_LAN_iface="pc2_veth0"
PC2_LAN_iface_ip=11.0.0.3

PC3_ns="LAN_pc3"
PC3_LAN_iface="pc3_veth0"
PC3_LAN_iface_ip=11.0.0.4

local_LAN_subnet=11.0.0.0

## client has to use these credentials to connect with ppp server
ppp_client_username="test01"
ppp_client_passwd="pass01"
ppp_client_ip="172.171.1.200"  #router Public IP
router_public_ip=$ppp_client_ip
ppp_server_ip="172.171.1.100"
ppp_subnet="172.171.1.0"
ppp_server_log_file="/var/log/pppd.log"

init () {

	## STEP1: enable local ip forward
	echo 1 > /proc/sys/net/ipv4/ip_forward

	## STEP2: create namespaces
	ip netns add $facebook_server_ns
	ip netns add $gmail_server_ns
	ip netns add $ISP_ppp_server_ns
	ip netns add $router_ppp_client_ns
	ip netns add $PC1_ns
	ip netns add $PC2_ns
	ip netns add $PC3_ns

	## STEP3: create veth pair and connect them back to back
	# GMAIL Server <--> ISP
	ip link add $gmail_server_iface netns $gmail_server_ns  type veth peer name $ISP_gmail_server_iface netns $ISP_ppp_server_ns
	# Facebook Server <--> ISP
	ip link add $facebook_server_iface netns $facebook_server_ns  type veth peer name $ISP_facebook_server_iface netns $ISP_ppp_server_ns
	# ISP WAN <--> Router WAN
	ip link add $ISP_WAN_ppp_server_iface netns $ISP_ppp_server_ns type veth peer name $router_WAN_ppp_client_iface netns $router_ppp_client_ns
	# Router LAN Port1 <--> PC 1 eth port
	ip link add $router_LAN_iface1 netns $router_ppp_client_ns  type veth peer name $PC1_LAN_iface netns $PC1_ns
	# Router LAN Port2 <--> PC 2 eth port
	ip link add $router_LAN_iface2 netns $router_ppp_client_ns  type veth peer name $PC2_LAN_iface netns $PC2_ns
	# Router LAN Port3 <--> PC 3 eth port
	ip link add $router_LAN_iface3 netns $router_ppp_client_ns  type veth peer name $PC3_LAN_iface netns $PC3_ns

	## STEP4: up the interfaces and create LAN bridge on Router
	# Gmail Server
	ip netns exec $gmail_server_ns ip link set $gmail_server_iface up
	# Facebook Server
	ip netns exec $facebook_server_ns ip link set $facebook_server_iface up
	# ISP WAN Provider
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_WAN_ppp_server_iface up
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_gmail_server_iface up
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_facebook_server_iface up
	# Router/GW
	# Router WAN
	ip netns exec $router_ppp_client_ns ip link set $router_WAN_ppp_client_iface up
	# Router LAN Port1
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface1 up
	# Router LAN Port2
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface2 up
	# Router LAN Port3
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface3 up

	# Router LAN brige: Create a brige for router LAN interface
	ip netns exec $router_ppp_client_ns brctl addbr $router_LAN_bridge_name
	ip netns exec $router_ppp_client_ns brctl addif $router_LAN_bridge_name $router_LAN_iface1
	ip netns exec $router_ppp_client_ns brctl addif $router_LAN_bridge_name $router_LAN_iface2
	ip netns exec $router_ppp_client_ns brctl addif $router_LAN_bridge_name $router_LAN_iface3
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_bridge_name up

	# PC1
	ip netns exec $PC1_ns ip link set $PC1_LAN_iface up
	# PC2
	ip netns exec $PC2_ns ip link set $PC2_LAN_iface up
	# PC3
	ip netns exec $PC3_ns ip link set $PC3_LAN_iface up

	## STEP5: PPPoE server(ISP provider) side options(its done in ISP provider machine)
	##        and start pppoe server
	cat > /etc/ppp/pppoe-server-options << EOF
require-chap
lcp-echo-interval 60 
lcp-echo-failure 5
debug
logfile $ppp_server_log_file
EOF

	# create pppoe client credentials in the server config file
	echo "\"$ppp_client_username\" * \"$ppp_client_passwd\" $ppp_client_ip" > /etc/ppp/chap-secrets

	# start pppoe-server, with local ip as $ppp_server_ip and remote ip as $ppp_client_ip
	ip netns exec $ISP_ppp_server_ns pkill -9 pppoe
	ip netns exec $ISP_ppp_server_ns ip addr flush dev $ISP_WAN_ppp_server_iface
	ip netns exec $ISP_ppp_server_ns ifconfig $ISP_WAN_ppp_server_iface down
	ip netns exec $ISP_ppp_server_ns ifconfig $ISP_WAN_ppp_server_iface up
	ip netns exec $ISP_ppp_server_ns pppoe-server -I $ISP_WAN_ppp_server_iface -L $ppp_server_ip #-R $ppp_client_ip

	## STEP6: PPPoE client(Router DUT) side settings
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

	ip netns exec $router_ppp_client_ns pppoeconf $router_WAN_ppp_client_iface
	#ven above client config overwrites chap-secrets as we are in namespace, not full-fledged systems
	echo "\"$ppp_client_username\" * \"$ppp_client_passwd\" $ppp_client_ip" > /etc/ppp/chap-secrets
	# above config line, creates some junk interface in the /etc/ppp/peers/dsl-provider
	correct_iface_line="nic-$router_WAN_ppp_client_iface"
	sed -i "/nic-/d" /etc/ppp/peers/dsl-provider
	echo "$correct_iface_line" >> /etc/ppp/peers/dsl-provider

	## STEP7: PPPoE client initiate connection
	ip netns exec $router_ppp_client_ns pon dsl-provider

	## <---------------- ppp --------------> tunnel should be established till this point

	## STEP8: Add IP addrs and routes
	# Gmail Server
	ip netns exec $gmail_server_ns ip addr add $gmail_server_ip/24 dev $gmail_server_iface
	ip netns exec $gmail_server_ns ip route add default via $ISP_gmail_server_iface_ip
	# Facebook Server
	ip netns exec $facebook_server_ns ip addr add $facebook_server_ip/24 dev $facebook_server_iface
	ip netns exec $facebook_server_ns ip route add default via $ISP_facebook_server_iface_ip
	# At Router/GW DUT side
	ip netns exec $router_ppp_client_ns ip addr add $router_LAN_bridge_ip/24 dev $router_LAN_bridge_name
	#ip netns exec $router_ppp_client_ns ip route add default via $ppp_server_ip --> once ppp0 is up, system auto addds default route
	# PC1
	ip netns exec $PC1_ns ip addr  add $PC1_LAN_iface_ip/24 dev $PC1_LAN_iface
	#ip netns exec $PC1_ns ip route add $ppp_subnet/24 via $router_LAN_bridge_ip
	ip netns exec $PC1_ns ip route add default via $router_LAN_bridge_ip
	# PC2
	ip netns exec $PC2_ns ip addr  add $PC2_LAN_iface_ip/24 dev $PC2_LAN_iface
	#ip netns exec $PC2_ns ip route add $ppp_subnet/24 via $router_LAN_bridge_ip
	ip netns exec $PC2_ns ip route add default via $router_LAN_bridge_ip
	# PC3
	ip netns exec $PC3_ns ip addr  add $PC3_LAN_iface_ip/24 dev $PC3_LAN_iface
	#ip netns exec $PC3_ns ip route add $ppp_subnet/24 via $router_LAN_bridge_ip
	ip netns exec $PC3_ns ip route add default via $router_LAN_bridge_ip

	# At ISP WAN side
	ip netns exec $ISP_ppp_server_ns ifconfig $ISP_gmail_server_iface $ISP_gmail_server_iface_ip up
	ip netns exec $ISP_ppp_server_ns ifconfig $ISP_facebook_server_iface $ISP_facebook_server_iface_ip up

	router_nat_init
}

clean () {
	router_nat_clear
	## client stop the connection
	ip netns exec $router_ppp_client_ns poff -a

	## server stop pppoe
	ip netns exec $ISP_ppp_server_ns pkill -9 pppoe

	## move interfaces to root namespace(which is 1)
	# Gmail server
	ip netns exec $gmail_server_ns ip link set $gmail_server_iface down
	ip netns exec $gmail_server_ns ip link set $gmail_server_iface netns 1
	# Facebook server
	ip netns exec $facebook_server_ns ip link set $facebook_server_iface down
	ip netns exec $facebook_server_ns ip link set $facebook_server_iface netns 1
	# ISP provider
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_WAN_ppp_server_iface down
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_WAN_ppp_server_iface netns 1
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_facebook_server_iface down
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_facebook_server_iface netns 1
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_gmail_server_iface down
	ip netns exec $ISP_ppp_server_ns ip link set $ISP_gmail_server_iface netns 1
	# Router
	ip netns exec $router_ppp_client_ns ip link set $router_WAN_ppp_client_iface down
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_bridge_name down
	ip netns exec $router_ppp_client_ns brctl delbr $router_LAN_bridge_name
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface1 down
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface2 down
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface3 down
	
	ip netns exec $router_ppp_client_ns ip link set $router_WAN_ppp_client_iface netns 1
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface1 netns 1
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface2 netns 1
	ip netns exec $router_ppp_client_ns ip link set $router_LAN_iface3 netns 1

	# PC1
	ip netns exec $PC1_ns ip link set $PC1_LAN_iface down
	ip netns exec $PC1_ns ip link set $PC1_LAN_iface netns 1
	# PC2
	ip netns exec $PC2_ns ip link set $PC2_LAN_iface down
	ip netns exec $PC2_ns ip link set $PC2_LAN_iface netns 1
	# PC3
	ip netns exec $PC3_ns ip link set $PC3_LAN_iface down
	ip netns exec $PC3_ns ip link set $PC3_LAN_iface netns 1

	# if you delete one veth interface, the peer also gets deleted as it is veth pair	
	ifconfig -a $ISP_facebook_server_iface 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $ISP_facebook_server_iface
	ifconfig -a $ISP_gmail_server_iface 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $ISP_gmail_server_iface
	ifconfig -a $ISP_WAN_ppp_server_iface 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $ISP_WAN_ppp_server_iface
	
	ifconfig -a $router_LAN_iface1 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $router_LAN_iface1
	ifconfig -a $router_LAN_iface2 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $router_LAN_iface2
	ifconfig -a $router_LAN_iface3 2>>/dev/null 1>>/dev/null
	[[ $? -eq 0 ]] && ip link delete $router_LAN_iface3
	
	ip netns delete $gmail_server_ns
	ip netns delete $facebook_server_ns
	ip netns delete $ISP_ppp_server_ns
	ip netns delete $router_ppp_client_ns
	ip netns delete $PC1_ns
	ip netns delete $PC2_ns
	ip netns delete $PC3_ns
}

ping_test () {
	#LAN PC <--> ISP (In realworld we dont know the ISP ipaddr)
	
	echo "Ping from LAN_PC1($PC1_LAN_iface_ip) --> Router LAN/Private IP($router_private_ip)"
	ip netns exec $PC1_ns ping $router_private_ip -p ab -s 64 -c 10

	echo "Ping from LAN_PC1($PC1_LAN_iface_ip) --> Router WAN/Public IP($router_public_ip)"
	ip netns exec $PC1_ns ping $router_public_ip -p cd -s 64 -c 10

	echo "Ping from LAN_PC2($PC2_LAN_iface_ip) --> Gmail($gmail_server_ip)"
	ip netns exec $PC2_ns ping $gmail_server_ip -p cd -s 64 -c 10

	echo "Ping from LAN_PC3($PC3_LAN_iface_ip) --> Facebook($facebook_server_ip)"
	ip netns exec $PC3_ns ping $facebook_server_ip -p cd -s 64 -c 10	
}

router_nat_init () {
	modprobe iptable_nat
	echo 1 > /proc/sys/net/ipv4/ip_forward
	ip netns exec $router_ppp_client_ns iptables-save > /iptables.old
	ip netns exec $router_ppp_client_ns iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE
	ip netns exec $router_ppp_client_ns iptables -A FORWARD -i $router_LAN_bridge_name -j ACCEPT
}

router_nat_clear () {
	iptables -t nat -F
        ip netns exec $router_ppp_client_ns iptables-restore < /iptables.old
}


if [[ $1 == "--init" ]]; then
	init
elif [[ $1 == "--clean" ]]; then
	clean
elif [[ $1 == "--ping" ]]; then
	ping_test
elif [[ $1 == "--exec" ]]; then
	_n=""
	if [[ ${2:0:2} == "PC" ]]; then
		_n="$2_ns"
		_n=${!_n}
	elif [[ $2 == "ISP" ]]; then
		_n=$ISP_ppp_server_ns
	elif [[ $2 == "DUT" ]]; then
		_n=$router_ppp_client_ns
	elif [[ $2 == "FB" ]]; then
		_n=$facebook_server_ns
	elif [[ $2 == "GM" ]]; then
		_n=$gmail_server_ns
	else
		echo "$0 $1 PC/ISP/DUT/FB/GM only supported"
		exit 0
	fi
	shift 2
	ip netns exec $_n $@
else
	echo "Usage: $0 --init/--clean/--ping/--exec"
fi
