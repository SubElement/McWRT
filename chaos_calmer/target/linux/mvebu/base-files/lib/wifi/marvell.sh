#!/bin/sh
append DRIVERS "marvell"

check_wifi_sw() {
	return 1
}

find_marvell_phy() {
        local device="$1"
	logger "chad- find_marvell_phy() $1"

        local macaddr="$(config_get "$device" macaddr | tr 'A-Z' 'a-z')"
        config_get phy "$device" phy
	logger "chad- macaddr=$macaddr"
	logger "chad- phy=$phy"
#        [ -z "$phy" -a -n "$macaddr" ] && {
#		logger "chad- if1"
#                cd /proc/net/hostap
#                for phy in $(ls -d wlan* 2>&-); do
#                        [ "$macaddr" = "$(cat /sys/class/net/${phy}/address)" ] || continue
#                        config_set "$device" phy "$phy"
#                        break
#                done
#                config_get phy "$device" phy
#        }
#        [ -n "$phy" -a -d "/proc/net/hostap/$phy" ] || {
#                echo "phy for wifi device $1 not found"
#		logger "chad- phy for wifi device $1 not found"
#                return 1
#        }
        [ -z "$macaddr" ] && {
                config_set "$device" macaddr "$(cat /sys/class/net/${phy}/address)"
		logger "chad- config_set $device macaddr $(cat /sys/class/net/${phy}/address)"
        }
        return 0
}

scan_marvell() {
	local device="$1"
	local wds
	local adhoc ahdemo sta ap monitor

	config_get disabled "$device" disabled
	
	config_get vifs "$device" vifs
	for vif in $vifs; do
	
		config_get ifname "$vif" ifname
		config_set "$vif" ifname "${ifname:-wdev}"
		
		config_get mode "$vif" mode
		case "$mode" in
			adhoc|ahdemo|sta|ap|monitor)
				append $mode "$vif"
			;;
			wds)
				config_get ssid "$vif" ssid
				[ -z "$ssid" ] && continue

				config_set "$vif" wds 1
				config_set "$vif" mode sta
				mode="sta"
				addr="$ssid"
				${addr:+append $mode "$vif"}
			;;
			*) echo "$device($vif): Invalid mode, ignored."; continue;;
		esac
	done

	case "${adhoc:+1}:${sta:+1}:${ap:+1}" in
		# valid mode combinations
		1::) wds="";;
		1::1);;
		:1:1)config_set "$device" nosbeacon 1;; # AP+STA, can't use beacon timers for STA
		:1:);;
		::1);;
		::);;
		*) echo "$device: Invalid mode combination in config"; return 1;;
	esac

	config_set "$device" vifs "${sta:+$sta }${ap:+$ap }${adhoc:+$adhoc }${ahdemo:+$ahdemo }${wds:+$wds }${monitor:+$monitor}"
}


disable_marvell() (
	local device="$1"

	set_wifi_down "$device"
	
	include /lib/network
	cd /sys/class/net
	for dev in wdev*; do
		[ -f "/var/run/wifi-${dev}.pid" ] &&
		kill "$(cat "/var/run/wifi-${dev}.pid")"
		ifconfig "$dev" down
		unbridge "$dev"
	done
	return 0
)

enable_marvell() {
	
	local device="$1"
	logger "chad- enable_marvell $1"
	config_set "$device" phy "$device"
	find_marvell_phy "$device" || return 0
	config_get phy "$device" phy
	echo $device > /tmp/test
	config_get channel "$device" channel
	config_get vifs "$device" vifs
	config_get txpower "$device" txpower
	
	logger "chad- enable_marvell phy=$phy"
	logger "chad- enable_marvell channel=$channel"
	logger "chad- enable_marvell vifs=$vifs"
	logger "chad- enable_marvell txpower=$txpower"

	[ auto = "$channel" ] && channel=0

	config_get_bool antdiv "$device" diversity
	config_get antrx "$device" rxantenna
	config_get anttx "$device" txantenna
	config_get_bool softled "$device" softled
	config_get antenna "$device" antenna
	config_get wmm "$device" wmm
	config_get htbw "$device" htbw
    config_get hwmode "$device" hwmode

	logger "chad- enable_marvell hwmode=$hwmode"

    case "$hwmode" in
       11b)  hwmode=1;;
       11g)  hwmode=2;;
       11bg) hwmode=3;;
       11n)  hwmode=4;;
       11gn) hwmode=6;;
       11a)  hwmode=8;;
       11an) hwmode=12;;
       11anac) hwmode=28;;  #mixed 5.2Ghz 11AC mixed mode 
       11bgnac) hwmode=23;; #mixed 2.4Ghz 11AC mixed mode
       *)    hwmode=7;;
    esac

	logger "chad- enable_marvell hwmode=$hwmode"

    iwpriv "$device" opmode $hwmode
	logger "chad- iwpriv $device opmode $hwmode"	
	iwpriv "$device" wmm $wmm
	logger "chad- iwpriv $device wmm $wmm"
	iwpriv "$device" htbw $htbw
	logger "chad- iwpriv $device htbw $htbw"
	iwconfig "$device" channel $channel >/dev/null 2>/dev/null
	logger "chad- iwconfig $device channel $channel"
	iwpriv "$device" setcmd "loadtxpwrtable /lib/Mamba_FCC_v1.2_5G4TX.ini"
	logger "chad- iwpriv $device setcmd loadtxpwrtable /lib/Mamba_FCC_v1.2_5G4TX.ini"
	ifconfig "$device" up
	logger "chad- ifconfig $device up"
	sleep 1

	for vif in $vifs; do
		local start_hostapd= vif_txpower= nosbeacon=
		config_get ifname "$vif" ifname
		logger "chad- ifname=$ifname"
		config_get ampdutx "$vif" ampdutx
		logger "chad- ampdutx=$ampdutx"
		config_get enc "$vif" encryption
		logger "chad- enc=$enc"

		iwpriv $ifname ampdutx 1
		logger "chad- iwpriv $ifname ampdutx 1"
		
		config_get amsdu "$vif" amsdu
		logger "chad- amsdu=$amsdu"
		iwpriv $ifname amsdu 1
		logger "chad- iwpriv $ifname amsdu 1"
		
		config_set "$vif" ifname "$ifname"
		
		config_get_bool hidden "$vif" hidden 0
		logger "chad- hidden=$hidden"
		iwpriv "$ifname" hidessid "$hidden"
		logger "chad- iwpriv $ifname hidessid $hidden"
		
		case "$enc" in
			wep*)
				case "$enc" in
					*shared*) wep_mode="restricted";;
					*)        wep_mode="open";;
				esac
				for idx in 1 2 3 4; do
					config_get key "$vif" "key${idx}"
					iwconfig "$ifname" key "[$idx]" "${key:-off}"
				done
				config_get key "$vif" key
				key="${key:-1}"
				case "$key" in
					[1234]) iwconfig "$ifname" key "[$key]" $wep_mode;;
					*) iwconfig "$ifname" key "$key" $wep_mode;;
				esac
			;;
			psk*|wpa*)
				start_hostapd=1
				logger "chad- start_hostapd=$start_hostapd"	
				config_get key "$vif" key
				logger "chad- key=$key"
			;;
		esac
		
		config_get maclist "$vif" maclist
		logger "chad- maclist=$maclist"
		[ -n "$maclist" ] && {
			# flush MAC list
			iwpriv "$ifname" filtermac deleteall
			for mac in $maclist; do
				mv_mac=`echo "$mac" | sed "s/://g"`
				iwpriv "$ifname" filtermac "add $mv_mac"
				logger "chad- iwpriv $ifname filtermac add $mv_mac"
			done
		}

		config_get macpolicy "$vif" macpolicy
		logger "chad- macpolicy=$macpolicy"
		case "$macpolicy" in
			allow)
				iwpriv "$ifname" filter 1
			;;
			deny)
				iwpriv "$ifname" filter 2
			;;
			*)
				iwpriv "$ifname" filter 0
			;;
		esac
		
		ifconfig "$ifname" up
		logger "chad- ifconfig $ifname up"

		sleep 1

		iwconfig "$device" commit
		logger "chad- iwconfig $device commit"

		config_get ssid "$vif" ssid
		logger "chad- ssid=$ssid"
		[ -n "$ssid" ] && {
			iwconfig "$ifname" essid on
			logger "chad- iwconfig $ifname essid on"
			iwconfig "$ifname" essid "$ssid"
			logger "chad- iwconfig $ifname essid $ssid"
		}

		set_wifi_up "$vif" "$ifname"
		logger "chad- mode=$mode"

		case "$mode:$enc" in
			ap:*)
				#config_get_bool isolate "$vif" isolate 0
				#iwpriv "$ifname" ap_bridge "$((isolate^1))"

				if [ -n "$start_hostapd" ] && eval "type hostapd_setup_vif" 2>/dev/null >/dev/null; then
					hostapd_setup_vif "$vif" marvell || {
						echo "enable_marvell($device): Failed to set up hostapd for interface $ifname" >&2
						logger "chad- enable_marvell($device): Failed to set up hostapd for interface $ifname"
						# make sure this wifi interface won't accidentally stay open without encryption
						ifconfig "$ifname" down
						logger "chad- ifconfig $ifname down"
						continue
					}
				fi
			;;
			wds:*|sta:*)
				if eval "type wpa_supplicant_setup_vif" 2>/dev/null >/dev/null; then
					wpa_supplicant_setup_vif "$vif" wext || {
						echo "enable_marvell($device): Failed to set up wpa_supplicant for interface $ifname" >&2
						ifconfig "$ifname" down
						continue
					}
				fi
			;;
			adhoc:wep*|adhoc:psk*|adhoc:wpa*)
				if eval "type wpa_supplicant_setup_vif" 2>/dev/null >/dev/null; then
					wpa_supplicant_setup_vif "$vif" marvell || {
						echo "enable_marvell($device): Failed to set up wpa"
						ifconfig "$ifname" down
						continue
					}
				fi
			;;
		esac
	done
}


detect_marvell() {
	sleep 1
}
