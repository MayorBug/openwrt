#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

WS_LEDS='green:mobile-1 green:mobile-2 green:lan green:wlan green:mobile-3 green:mobile-4'

ws_log() {
	echo "WS1610 transition: $*"
	logger -t ws1610-transition -- "$*" 2>/dev/null || true
}

ws_led_path() {
	local name="$1" alt=""

	case "$name" in
	wlan) name='green:wlan' ;;
	lan) name='green:lan' ;;
	failure) name='green:mobile-4'; alt='green:sim2' ;;
	esac

	if [ -d "/sys/class/leds/$name" ]; then
		echo "/sys/class/leds/$name"
	elif [ -n "$alt" ] && [ -d "/sys/class/leds/$alt" ]; then
		echo "/sys/class/leds/$alt"
	fi
}

ws_led_off() {
	local path="$1"
	[ -d "$path" ] || return 0
	echo none > "$path/trigger" 2>/dev/null || true
	echo 0 > "$path/brightness" 2>/dev/null || true
}

ws_led_on() {
	local path="$1" max=1
	[ -d "$path" ] || return 0
	[ ! -r "$path/max_brightness" ] || max="$(cat "$path/max_brightness")"
	echo none > "$path/trigger" 2>/dev/null || true
	echo "$max" > "$path/brightness" 2>/dev/null || true
}

ws_led_timer() {
	local path="$1" on="$2" off="$3"
	[ -d "$path" ] || return 0
	echo timer > "$path/trigger" 2>/dev/null || return 0
	echo "$on" > "$path/delay_on" 2>/dev/null || true
	echo "$off" > "$path/delay_off" 2>/dev/null || true
}

ws_led_all_off() {
	local name path
	for name in $WS_LEDS; do
		path="/sys/class/leds/$name"
		ws_led_off "$path"
	done
}

ws_led_status() {
	local phase="$1" name path

	ws_led_all_off
	case "$phase" in
	prepare)
		path="$(ws_led_path wlan)"
		[ -z "$path" ] || ws_led_timer "$path" 500 500
		;;
	preflight)
		path="$(ws_led_path lan)"
		[ -z "$path" ] || ws_led_timer "$path" 500 500
		;;
	destructive)
		for name in $WS_LEDS; do
			ws_led_timer "/sys/class/leds/$name" 100 100
		done
		;;
	failure)
		path="$(ws_led_path failure)"
		[ -z "$path" ] || ws_led_timer "$path" 50 50
		;;
	success)
		for name in $WS_LEDS; do
			ws_led_on "/sys/class/leds/$name"
		done
		;;
	esac
}

ws_fail() {
	ws_log "ERROR: $*"
	ws_led_status failure
	if [ -e /tmp/ws1610-converter-active ]; then
		ws_log 'Conversion stopped. Power-cycle recovery requires mtk_uartboot.'
		while sleep 3600; do :; done
	fi
	exit 1
}

ws_board_name() {
	[ -r /tmp/sysinfo/board_name ] || {
		echo generic
		return 0
	}
	cat /tmp/sysinfo/board_name
}

ws_find_mtd() {
	local wanted="$1" path
	for path in /sys/class/mtd/mtd[0-9]*; do
		case "${path##*/}" in
		*ro) continue ;;
		esac
		[ -r "$path/name" ] || continue
		[ "$(cat "$path/name")" = "$wanted" ] || continue
		basename "$path"
		return 0
	done
	return 1
}

ws_check_mtd() {
	local name="$1" offset="$2" size="$3" mtd path actual
	offset=$((offset + 0))
	size=$((size + 0))
	mtd="$(ws_find_mtd "$name")" || ws_fail "missing MTD partition $name"
	path="/sys/class/mtd/$mtd"
	[ "$(cat "$path/size")" -eq "$size" ] ||
		ws_fail "$name has the wrong size"
	[ -r "$path/offset" ] || ws_fail "$name has no exported offset"
	actual="$(cat "$path/offset")"
	[ "$actual" -eq "$offset" ] || ws_fail "$name has the wrong offset"
	echo "$mtd"
}

ws_find_volume() {
	local ubi="$1" wanted="$2" path
	for path in "/sys/class/ubi/$ubi"_[0-9]*; do
		[ -r "$path/name" ] || continue
		[ "$(cat "$path/name")" = "$wanted" ] || continue
		basename "$path"
		return 0
	done
	return 1
}

ws_ubi_for_mtd() {
	local mtd_num="${1#mtd}" path
	for path in /sys/class/ubi/ubi[0-9]*; do
		[ -r "$path/mtd_num" ] || continue
		[ "$(cat "$path/mtd_num")" = "$mtd_num" ] || continue
		basename "$path"
		return 0
	done
	return 1
}

ws_attach_mtd() {
	local mtd="$1" ubi
	ubi="$(ws_ubi_for_mtd "$mtd")" && {
		echo "$ubi"
		return 0
	}
	ubiattach /dev/ubi_ctrl -m "${mtd#mtd}" >/dev/null ||
		ws_fail "unable to attach $mtd"
	ubi="$(ws_ubi_for_mtd "$mtd")" ||
		ws_fail "$mtd attached without a UBI device"
	echo "$ubi"
}

ws_require_vendor_slot() {
	case "$1" in
	ubi|ubi2)
		return 0
		;;
	*)
		ws_fail "transition must boot from vendor ubi or ubi2, not $1"
		;;
	esac
}

ws_select_transition_slot() {
	local name mtd ubi installer kernel

	WS_TRANSITION_MTD_NAME=
	WS_TRANSITION_UBI=
	WS_TRANSITION_INSTALLER=
	WS_TRANSITION_KERNEL=

	for name in ubi ubi2; do
		ws_require_vendor_slot "$name"
		mtd="$(ws_find_mtd "$name")" ||
			ws_fail "missing MTD partition $name"
		ubi="$(ws_attach_mtd "$mtd")"
		installer="$(ws_find_volume "$ubi" installer)" || continue
		kernel="$(ws_find_volume "$ubi" kernel)" ||
			ws_fail "$name has an installer volume but no kernel volume"
		[ -z "$WS_TRANSITION_UBI" ] ||
			ws_fail 'installer volumes exist in both vendor slots'
		WS_TRANSITION_MTD_NAME="$name"
		WS_TRANSITION_UBI="$ubi"
		WS_TRANSITION_INSTALLER="$installer"
		WS_TRANSITION_KERNEL="$kernel"
	done

	[ -n "$WS_TRANSITION_UBI" ] ||
		ws_fail 'no vendor slot contains the transition installer volume'
}

ws_file_size() {
	wc -c < "$1" | tr -d ' '
}

ws_check_factory() {
	local file="$1" size magic mac first allzero=1 allff=1 value
	size="$(ws_file_size "$file")"
	[ "$size" -eq 2097152 ] || ws_fail 'Factory data is not exactly 2 MiB'
	magic="$(dd if="$file" bs=1 count=2 2>/dev/null | od -b |
		awk 'NR == 1 { print $2 $3 }')"
	[ "$magic" = 201171 ] || ws_fail 'Factory data lacks the MT7981 EEPROM marker'
	mac="$(dd if="$file" bs=1 skip=4 count=6 2>/dev/null | od -b |
		awk 'NR == 1 { print $2, $3, $4, $5, $6, $7 }')"
	set -- $mac
	[ "$#" -eq 6 ] || ws_fail 'unable to read Factory base MAC'
	first=$((0$1))
	[ $((first % 2)) -eq 0 ] || ws_fail 'Factory base MAC is multicast'
	for value in "$@"; do
		value=$((0$value))
		[ "$value" -eq 0 ] || allzero=0
		[ "$value" -eq 255 ] || allff=0
	done
	[ "$allzero" -eq 0 ] || ws_fail 'Factory base MAC is all zeroes'
	[ "$allff" -eq 0 ] || ws_fail 'Factory base MAC is erased'
}

ws_hash_prefix() {
	local source="$1" size="$2" output="$3" blocks
	blocks=$(( (size + 4095) / 4096 ))
	dd if="$source" of="$output" bs=4096 count="$blocks" 2>/dev/null
	head -c "$size" "$output" | sha256sum | awk '{print $1}'
}
