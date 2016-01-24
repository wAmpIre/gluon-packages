#!/bin/sh
# Netmon Configurator (C) 2010-2012 Freifunk Oldenburg
# Lizenz: GPL v3

#Get the configuration from the uci configuration file
#If it does not exists, then get it from a normal bash file with variables.
if [ -f /etc/config/configurator ];then
	API_IPV4_ADRESS=`uci get configurator.@api[0].ipv4_address`
	API_IPV6_ADRESS=`uci get configurator.@api[0].ipv6_address`
	API_TIMEOUT=`uci get configurator.@api[0].timeout`
	API_RETRY=`uci get configurator.@api[0].retry`
	SCRIPT_VERSION=`uci get configurator.@script[0].version`
	SCRIPT_ERROR_LEVEL=`uci get configurator.@script[0].error_level`
	SCRIPT_LOGFILE=`uci get configurator.@script[0].logfile`
	SCRIPT_SYNC_HOSTNAME=`uci get configurator.@script[0].sync_hostname`
	CRAWL_METHOD=`uci get configurator.@crawl[0].method`
	CRAWL_ROUTER_ID=`uci get configurator.@crawl[0].router_id`
	CRAWL_UPDATE_HASH=`uci get configurator.@crawl[0].update_hash`
	CRAWL_NICKNAME=`uci get configurator.@crawl[0].nickname`
	CRAWL_PASSWORD=`uci get configurator.@crawl[0].password`
	AUTOADD_IPV6_ADDRESS=`uci get configurator.@netmon[0].autoadd_ipv6_address`
else
	. `dirname $0`/configurator_config
fi

API_RETRY=$(($API_RETRY - 1))

if [ $SCRIPT_ERROR_LEVEL -gt "1" ]; then
	err() {
		echo "$(date) [configurator]: $1" >> $SCRIPT_LOGFILE
	}
else
	err() {
		:
	}
fi

if [ "$API_IPV6_ADRESS" = "1" -a "$API_IPV4_ADRESS" = "1" ]; then
	# autoconfiguration
	PREFIX=$(uci get network.local_node_route6.target | cut -d: -f 1-4)
	COMMUNITY_ESSID=$(uci get wireless.client_radio0.ssid)

	netmon_ipaddr="${PREFIX%:}::42"
	netmon_hostname="netmon.$COMMUNITY_ESSID"

	hosts_ipaddr=$(grep -e $netmon_hostname /etc/hosts | awk '{ print $1 }')	

	if [ "$hosts_ipaddr" = "$netmon_ipaddr" ]; then
		err "ipaddr in /etc/hosts already correct"
	else
		err "fixing netmon ipaddr in /etc/hosts ..."
		sed -i -e "/$netmon_hostname/d" /etc/hosts
		echo $netmon_ipaddr $netmon_hostname >> /etc/hosts
	fi

	API_IPV6_ADRESS=$netmon_hostname
fi

if [[ $API_IPV4_ADRESS != "1" ]]; then
	netmon_api=$API_IPV4_ADRESS
else
	netmon_api=$API_IPV6_ADRESS
fi

sync_hostname() {
	err "Syncing hostname"
	api_return=$(wget -T $API_TIMEOUT -q -O - "http://$netmon_api/api_csv_configurator.php?section=get_hostname&authentificationmethod=$CRAWL_METHOD&nickname=$CRAWL_NICKNAME&password=$CRAWL_PASSWORD&router_auto_update_hash=$CRAWL_UPDATE_HASH&router_id=$CRAWL_ROUTER_ID")
	ret=${api_return%%,*}
	if [ "$ret" != "success" ]; then
		err "There was an error fetching the hostname"
		exit 0
	elif [ "$ret" = "success" ]; then
		netmon_hostname=${api_return%,*}
		netmon_hostname=${netmon_hostname#*,}
		
		#check for valid hostname as specified in rfc 1123
		#see http://stackoverflow.com/a/3824105
		regex='^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])'
		regex=$regex'(\.([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9]))*$'
		if [ ${#netmon_hostname} -le 255 ]; then
			if echo -n $netmon_hostname | egrep -q "$regex"; then
				if [ "$netmon_hostname" != "`cat /proc/sys/kernel/hostname`" ]; then
					err "Setting new hostname: $netmon_hostname"
					uci set system.@system[0].hostname=$netmon_hostname
					uci commit
					echo $netmon_hostname > /proc/sys/kernel/hostname
				else
					err "Hostname is up to date"
				fi
			else
				err "Hostname ist malformed"
				exit 0
			fi
		else
			err "Hostname exceeds the maximum length of 255 characters"
			exit 0
		fi
	fi
}

sync_coords () {
	err "Syncing coordiantes"
	api_return=$(wget -T $API_TIMEOUT -q -O - "http://$netmon_api/api_csv_configurator.php?section=get_coords&router_id=$CRAWL_ROUTER_ID")
	ret=${api_return%%,*}
	if [ "$ret" != "success" ]; then
		err "There was an error fetching the coordinates"
		return 1
	fi
	coords=${api_return/success,/}
	if echo $coords | grep -q '^0,0,\?$' ; then
		err "Netmon has no coordinates"
		return 0
	fi
	if echo $coords | egrep -qo '^[+-]?[0-9]+\.[0-9]+,[+-]?[0-9]+\.[0-9]+'; then
		GET_NETMON_COORDS=`uci -q get gluon-node-info.@location[0].get_netmon_coords`
		if [ "x$GET_NETMON_COORDS" != "x0" ]; then
			LATITUDE=`uci -q get gluon-node-info.@location[0].latitude`
			LONGITUDE=`uci -q get gluon-node-info.@location[0].longitude`
			SHARE_LOCATION=`uci -q get gluon-node-info.@location[0].share_location`
			if [ "x$SHARE_LOCATION" == "x1" -o "x$LATITUDE" == "x" -o "x$LONGITUDE" == "x" ]; then
				eval `echo $coords | awk -F, '{ print "lat="$1; print "long="$2; }'`
				if [ "x$SHARE_LOCATION" != "x1" -o "x$LATITUDE" != "x$lat" -o "x$LONGITUDE" != "x$long" ]; then
					uci -q set gluon-node-info.@location[0].share_location=1
					uci -q set gluon-node-info.@location[0].get_netmon_coords=1
					uci -q set gluon-node-info.@location[0].latitude=$lat
					uci -q set gluon-node-info.@location[0].longitude=$long
					uci -q commit
				fi
			fi
		fi
	fi
}

assign_router() {
	hostname=`cat /proc/sys/kernel/hostname`
	
	#Choose right login String
	#Here maybe a ; to much at the end..??
	login_strings=$(awk '{ mac=toupper($1); gsub(":", "", mac); printf mac ";" }' /sys/class/net/br-client/address 
/sys/class/net/eth0/address /sys/class/net/ath0/address 2> /dev/null)
	ergebnis=$(wget -T $API_TIMEOUT -q -O - "http://$netmon_api/api_csv_configurator.php?section=test_login_strings&login_strings=$login_strings")
	router_auto_assign_login_string=${ergebnis#*;}
	ergebnis=${ergebnis%;*}
	if [ "$ergebnis" = "error" ]; then
		router_auto_assign_login_string=${login_strings%%;*}
		err "A router with this login string does not exist: $login_strings"
		err "Using $router_auto_assign_login_string as login string"
	fi

	#Try to assign Router with choosen login string
	ergebnis=$(wget -T $API_TIMEOUT -q -O - "http://$netmon_api/api_csv_configurator.php?section=router_auto_assign&router_auto_assign_login_string=$router_auto_assign_login_string&hostname=$hostname")
	ret=${ergebnis%%;*}
	errstr=${ergebnis#*;}
	errstr=${errstr%%;*}
	if [ "$ret" != "success" ]; then
		err "The router has not been assigned to a router in Netmon"
		err "Failure on router_auto_assign: $errstr. Exiting"
		exit 0
	elif [ "$ret" = "success" ]; then
		update_hash=${ergebnis%;*;*}
		update_hash=${update_hash##*;}
		api_key=${ergebnis##*;}
		#write new config
		uci set configurator.@crawl[0].router_id=$errstr
		uci set configurator.@crawl[0].update_hash=$update_hash
		uci set configurator.@api[0].api_key=$api_key
		#set also new router id for nodewatcher
		#uci set nodewatcher.@crawl[0].router_id=$errstr

		err "The router $errstr has been assigned with a router in Netmon"
		uci commit

		CRAWL_METHOD=`uci get configurator.@crawl[0].method`
		CRAWL_ROUTER_ID=$errstr
		CRAWL_UPDATE_HASH=$update_hash
		CRAWL_NICKNAME=`uci get configurator.@crawl[0].nickname`
		CRAWL_PASSWORD=`uci get configurator.@crawl[0].password`
	fi
}

autoadd_ipv6_address() {
	err "Doing IPv6 autoadd"
	ipv6_link_local_addr=$(ip addr show dev br-client scope link | awk '/inet6/{print $2}')
	ipv6_link_local_netmask=${ipv6_link_local_addr##*/}
	ipv6_link_local_addr=${ipv6_link_local_addr%%/*}
	ergebnis=$(wget -T $API_TIMEOUT -q -O - "http://$netmon_api/api_csv_configurator.php?section=autoadd_ipv6_address&authentificationmethod=$CRAWL_METHOD&nickname=$CRAWL_NICKNAME&password=$CRAWL_PASSWORD&router_auto_update_hash=$CRAWL_UPDATE_HASH&router_id=$CRAWL_ROUTER_ID&networkinterface_name=br-client&ip=$ipv6_link_local_addr&netmask=$ipv6_link_local_netmask&ipv=6")
	ret=${ergebnis%%,*}
	if [ "$ret" = "success" ]; then
		uci set configurator.@netmon[0].autoadd_ipv6_address='0'
		uci commit
		err "The IPv6 address of the router $CRAWL_ROUTER_ID has been added to the router in Netmon"
		err "IPv6 Autoadd has been disabled cause it is no longer necesarry"
	else
		routerid=${ergebnis##*,}
		if [ "$routerid" == "$CRAWL_ROUTER_ID" ]; then
			err "The IPv6 address already exists in Netmon on this router. Maybe because of a previos assignment"
			uci set configurator.@netmon[0].autoadd_ipv6_address='0'
			uci commit
			err "IPv6 Autoadd has been disabled cause it is no longer necesarry"
		else 
			err "The IPv6 address already exists in Netmon on another router $routerid"
		fi
	fi
}

if [ $CRAWL_METHOD == "login" ]; then
	err "Authentification method is: username and passwort"
elif [ $CRAWL_METHOD == "hash" ]; then
	err "Authentification method: autoassign and hash"
	err "Checking if the router is already assigned to a router in Netmon"
	if [ $CRAWL_UPDATE_HASH == "1" ]; then
		err "The router is not assigned to a router in Netmon"
		err "Trying to assign the router"
		assign_router
	else
		err "The router is already assigned to a router in Netmon"
	fi
fi

if [[ $AUTOADD_IPV6_ADDRESS = "1" ]]; then
	autoadd_ipv6_address
fi

if [[ $SCRIPT_SYNC_HOSTNAME = "1" ]]; then
	sync_hostname
fi

sync_coords

