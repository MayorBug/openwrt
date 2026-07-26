#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

TOPDIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
STAGE="$TOPDIR/package/utils/ws1610-transition/files/usr/libexec/ws1610-transition-stage"
CONVERT="$TOPDIR/package/utils/ws1610-transition/files/usr/libexec/ws1610-transition-convert"
COMMON="$TOPDIR/package/utils/ws1610-transition/files/usr/libexec/ws1610-transition-common.sh"
UBOOT_PATCH="$TOPDIR/package/boot/uboot-mediatek/patches/504-add-huasifei-ws1610.patch"
UBI_DTS="$TOPDIR/target/linux/mediatek/dts/mt7981b-huasifei-ws1610-ubi.dts"
PREINIT="$TOPDIR/target/linux/mediatek/base-files/lib/preinit/05_set_preinit_iface"
NETWORK="$TOPDIR/target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
IMAGE_MK="$TOPDIR/target/linux/mediatek/image/filogic.mk"
MKITS="$TOPDIR/scripts/mkits.sh"
ENVTOOLS="$TOPDIR/package/boot/uboot-tools/uboot-envtools/files/uboot-envtools.sh"
UBOOT_TOOLS="$TOPDIR/package/boot/uboot-tools/Makefile"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require() {
	grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"
}

reject() {
	if grep -Eq -- "$2" "$1"; then
		fail "$1 unexpectedly contains: $2"
	fi
}

for script in \
	"$TOPDIR/scripts/ws1610-transition-build.sh" \
	"$TOPDIR/scripts/ws1610-transition-test.sh" \
	"$TOPDIR/package/utils/ws1610-transition/files/etc/init.d/ws1610-transition" \
	"$TOPDIR/package/utils/ws1610-transition/files/etc/uci-defaults/99-ws1610-transition-wifi" \
	"$COMMON" "$STAGE" "$CONVERT"; do
	sh -n "$script" || fail "$script does not parse as POSIX shell"
done

converter_preinit="$(sed -n '/huasifei,ws1610-converter)/,/;;/p' "$PREINIT")"
echo "$converter_preinit" | grep -Fq 'return 0' ||
	fail 'converter preinit does not return without configuring Ethernet'
if echo "$converter_preinit" | grep -Fq 'ip link'; then
	fail 'converter preinit attempts to configure Ethernet'
fi

converter_network="$(sed -n '/huasifei,ws1610-converter)/,/;;/p' "$NETWORK")"
[ "$converter_network" = "	huasifei,ws1610-converter)
		;;" ] || fail 'converter board setup is not an explicit empty network case'

for profile in huasifei_ws1610-transition huasifei_ws1610-converter; do
	profile_packages="$(sed -n "/^define Device\/$profile$/,/^endef$/p" "$IMAGE_MK")"
	echo "$profile_packages" | grep -Fq -- '-uboot-envtools' ||
		fail "$profile does not exclude uboot-envtools"
done
final_packages="$(sed -n '/^define Device\/huasifei_ws1610-ubi$/,/^endef$/p' "$IMAGE_MK")"
if echo "$final_packages" | grep -Fq -- '-uboot-envtools'; then
	fail 'final WS1610 profile excludes uboot-envtools'
fi
require "$TOPDIR/target/linux/mediatek/filogic/target.mk" 'uboot-envtools'
require "$MKITS" 'compression = \"none\";'
require "$ENVTOOLS" 'config" 2>/dev/null ||'
require "$UBOOT_TOOLS" 'PKG_RELEASE:=3'

mkits_work="$(mktemp -d)"
touch "$mkits_work/kernel" "$mkits_work/initrd"
sh "$MKITS" -A arm64 -C lzma -a 0x48000000 -e 0x48000000 \
	-v test -k "$mkits_work/kernel" -i "$mkits_work/initrd" \
	-c config-1 -o "$mkits_work/test.its"
sed -n '/^[[:space:]]*initrd-1 {/,/^[[:space:]]*};/p' \
	"$mkits_work/test.its" | grep -Fq 'compression = "none";' ||
	fail 'generated initrd FIT node lacks uncompressed metadata'
rm -rf "$mkits_work"

for slot in ubi ubi2; do
	(
		. "$COMMON"
		ws_fail() { return 1; }
		ws_require_vendor_slot "$slot"
	) || fail "vendor slot $slot was rejected"
done
if (
	. "$COMMON"
	ws_fail() { return 1; }
	ws_require_vendor_slot unsupported
); then
	fail 'unsupported vendor root MTD was accepted'
fi

test_transition_slot() (
	target="$1"
	. "$COMMON"
	ws_fail() { exit 1; }
	ws_find_mtd() {
		case "$1" in
		ubi) echo mtd5 ;;
		ubi2) echo mtd6 ;;
		esac
	}
	ws_attach_mtd() {
		case "$1" in
		mtd5) echo ubi0 ;;
		mtd6) echo ubi1 ;;
		esac
	}
	ws_find_volume() {
		case "$1" in
		ubi0) slot=ubi ;;
		ubi1) slot=ubi2 ;;
		esac
		[ "$target" = both ] || [ "$target" = "$slot" ] || return 1
		case "$2" in
		installer) echo "${1}_0" ;;
		kernel) echo "${1}_1" ;;
		*) return 1 ;;
		esac
	}
	ws_select_transition_slot
	[ "$WS_TRANSITION_MTD_NAME" = "$target" ]
)

for slot in ubi ubi2; do
	test_transition_slot "$slot" ||
		fail "transition payload in $slot was not selected"
done
if test_transition_slot none; then
	fail 'slot discovery accepted a layout without an installer volume'
fi
if test_transition_slot both; then
	fail 'slot discovery accepted installer volumes in both slots'
fi

require "$STAGE" "root=/dev/ram0"
require "$STAGE" 'ws_select_transition_slot'
require "$STAGE" 'selected transition payload in vendor $root_mtd_name ($root_ubi)'
reject "$STAGE" '^root_ubi=ubi0$'
reject "$COMMON" 'ws_root_ubi_mtd_name'
require "$STAGE" "mtd dump Factory"
require "$STAGE" "MAX_FIT_SIZE=\$((64 * 1024 * 1024))"
require "$STAGE" "fit_check_sign -f"
require "$STAGE" "kernel volume readback mismatch"
require "$STAGE" "not enough UBI space for the conversion FIT"
require "$COMMON" "Factory data is not exactly 2 MiB"
require "$COMMON" "Factory data lacks the MT7981 EEPROM marker"
require "$COMMON" "Factory base MAC is multicast"
require "$COMMON" 'offset=$((offset + 0))'
require "$COMMON" 'size=$((size + 0))'
require "$COMMON" '*ro) continue'
require "$COMMON" '/tmp/sysinfo/board_name'
reject "$COMMON" '^\.[[:space:]]+/lib/functions'
require "$COMMON" 'ubi|ubi2)'
require "$COMMON" 'installer volumes exist in both vendor slots'
require "$COMMON" 'no vendor slot contains the transition installer volume'

require "$CONVERT" "root=/dev/ram0"
require "$CONVERT" "all required data is in RAM and verified"
require "$CONVERT" "ws_check_mtd ubi-convert"
require "$CONVERT" "! -name '*ro'"
require "$CONVERT" "write_volume factory static"
require "$CONVERT" "write_volume fip static"
require "$CONVERT" "write_volume recovery dynamic"
require "$CONVERT" "write_volume fit dynamic"
require "$CONVERT" "writing final BL2 last"
require "$CONVERT" "converter does not see the two-part raw NAND layout"
require "$CONVERT" "volume readback mismatch"
reject "$CONVERT" 'ENV_SIZE|ubimkvol .* ubootenv'
reject "$CONVERT" 'ws_find_volume ubi0 ubootenv'
reject "$CONVERT" 'empty redundant environment volumes created'

factory_line="$(grep -n '^write_volume factory' "$CONVERT" | cut -d: -f1)"
fip_line="$(grep -n '^write_volume fip' "$CONVERT" | cut -d: -f1)"
recovery_line="$(grep -n '^write_volume recovery' "$CONVERT" | cut -d: -f1)"
fit_line="$(grep -n '^write_volume fit' "$CONVERT" | cut -d: -f1)"
bl2_line="$(grep -n '^mtd erase bl2' "$CONVERT" | cut -d: -f1)"
ram_line="$(grep -n 'all required data is in RAM and verified' "$CONVERT" | cut -d: -f1)"
erase_line="$(grep -n '^ubiformat ' "$CONVERT" | cut -d: -f1)"
[ "$factory_line" -lt "$fip_line" ] &&
	[ "$fip_line" -lt "$recovery_line" ] &&
	[ "$recovery_line" -lt "$fit_line" ] &&
	[ "$fit_line" -lt "$bl2_line" ] || fail 'destructive write order changed'
[ "$ram_line" -lt "$erase_line" ] || fail 'NAND erase can occur before RAM verification'

reject "$STAGE" '(^|[[:space:]])tftp([[:space:]]|$)'
reject "$CONVERT" '(^|[[:space:]])tftp([[:space:]]|$)'
reject "$UBOOT_PATCH" '^\+CONFIG_NMBM(=|_)'
reject "$UBOOT_PATCH" 'noboot|replacevol|boot_first=|pstore check|CONFIG_CMD_PSTORE'
require "$UBI_DTS" \
	'model = "Huasifei WS1610 (OpenWrt U-Boot UBI layout)";'
reject "$UBI_DTS" '^[[:space:]]*model[[:space:]]+"'

require "$UBOOT_PATCH" \
	'bootmenu_confirm_return=askenv - Press ENTER to return to menu ; bootmenu 60'
require "$UBOOT_PATCH" 'bootmenu_title=      ( ( ( OpenWrt ) ) )'
require "$UBOOT_PATCH" \
	'setenv bootmenu_title "$bootmenu_title       $ver"'

require "$UBOOT_PATCH" 'boot_tftp=tftpboot $loadaddr $bootfile'
require "$UBOOT_PATCH" \
	'iminfo $loadaddr && bootm $loadaddr#$bootconf'
require "$UBOOT_PATCH" \
	'boot_tftp_write_recovery=tftpboot $loadaddr $bootfile'
require "$UBOOT_PATCH" \
	'iminfo $loadaddr && run ubi_write_recovery'
require "$UBOOT_PATCH" \
	'boot_tftp_write_production=tftpboot $loadaddr $bootfile_upg'
require "$UBOOT_PATCH" \
	'iminfo $loadaddr && run ubi_write_production'

require "$UBOOT_PATCH" \
	'preboot=if env exists _firstboot && run ubi_installed'
require "$UBOOT_PATCH" \
	'then setenv _firstboot && run _switch_to_menu && run _init_env ; fi'
require "$UBOOT_PATCH" \
	'ubi_installed=ubi part ubi && ubi check factory && ubi check fip'
require "$UBOOT_PATCH" \
	'ubi check recovery && ubi check fit'
reject "$UBOOT_PATCH" 'ubi_installed=.*ubootenv'
require "$UBOOT_PATCH" \
	'ubi_create_env=ubi check ubootenv || ubi create ubootenv 0x1f000 dynamic'
require "$UBOOT_PATCH" \
	'ubi check ubootenv2 || ubi create ubootenv2 0x1f000 dynamic'
require "$UBOOT_PATCH" \
	'ubi check ubootenv && ubi check ubootenv2'
require "$UBOOT_PATCH" \
	'_init_env=setenv _init_env && run ubi_create_env && saveenv && saveenv'
require "$UBOOT_PATCH" \
	'ubi_verify_install=ubi part ubi && ubi check factory && ubi check fip'
require "$UBOOT_PATCH" \
	'ubi check ubootenv && ubi check ubootenv2'

require "$UBOOT_PATCH" \
	'ubi_prepare_rootfs=if ubi check rootfs_data ; then true'
require "$UBOOT_PATCH" \
	'ubi create rootfs_data $rootfs_data_max dynamic ||'
require "$UBOOT_PATCH" 'ubi create rootfs_data - dynamic'
reject "$UBOOT_PATCH" 'ubi create rootfs_data dynamic'

for dts in "$TOPDIR"/target/linux/mediatek/dts/mt7981b-huasifei-ws1610*.dts; do
	reject "$dts" 'spi[_-]nand@0'
	require "$dts" 'nand@0 {'
done

selector_tool='wto''em'
if grep -R -Fq -- "$selector_tool" \
	"$TOPDIR/package/utils/ws1610-transition" \
	"$TOPDIR/scripts/ws1610-transition"* \
	"$TOPDIR/docs/ws1610-transition.md"; then
	fail 'transition sources or documentation contain the vendor slot tool'
fi
reject "$STAGE" 'mtd[[:space:]]+(erase|write).*woem'

require "$TOPDIR/target/linux/mediatek/image/filogic.mk" "prepend-64k"
require "$TOPDIR/target/linux/mediatek/image/filogic.mk" \
	'ARTIFACT/vendor-to-ubi.bin := append-image-stage initramfs-stage.itb'
require "$TOPDIR/target/linux/mediatek/image/filogic.mk" \
	'define Device/huasifei_ws1610-converter'
require "$TOPDIR/target/linux/mediatek/dts/mt7981b-huasifei-ws1610-converter.dts" \
	'label = "ubi-convert";'
require "$TOPDIR/docs/ws1610-transition.md" 'unique validated `installer` volume'
require "$TOPDIR/docs/ws1610-transition.md" "SIM2 LED, rapid blink"
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'Refusing to build a release archive from a dirty source tree.'
require "$TOPDIR/scripts/ws1610-transition-build.sh" 'build-provenance.txt'
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	"Staging FIT does not contain an initramfs."
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	"Staging FIT initramfs lacks uncompressed metadata."
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	"reject_envtools \"\$WORK/installer/initrd-base.cpio\" 'Converter initramfs'"
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	"reject_envtools \"\$WORK/stage-initrd.cpio\" 'Staging initramfs'"
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'*huasifei_ws1610-transition*squashfs-factory.bin'
reject "$TOPDIR/scripts/ws1610-transition-build.sh" 'ws1610-vendor-backup'
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'huasifei_ws1610-converter) compression=GZIP'
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'CONFIG_TARGET_INITRAMFS_COMPRESSION_$compression=y'
require "$TOPDIR/scripts/ws1610-transition-build.sh" 'CONFIG_RD_GZIP=y'
require "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'gzip -dc "$WORK/initrd.cpio.gz"'
reject "$TOPDIR/scripts/ws1610-transition-build.sh" \
	'xz -dc "$WORK/initrd.cpio.xz"'
require "$TOPDIR/package/utils/busybox/Config-defaults.in" \
	'default y if TARGET_mediatek_filogic_DEVICE_huasifei_ws1610-transition'
for profile in huasifei_ws1610-transition huasifei_ws1610-converter; do
	sed -n '/^config BUSYBOX_DEFAULT_OD$/,/^config BUSYBOX_DEFAULT_PASTE$/p' \
		"$TOPDIR/package/utils/busybox/Config-defaults.in" |
		grep -Fq "default y if TARGET_mediatek_filogic_DEVICE_$profile" ||
		fail "BusyBox od is not enabled for $profile"
done
require "$TOPDIR/package/utils/ws1610-transition/files/etc/uci-defaults/99-ws1610-transition-wifi" \
	"OpenWrt-WS1610-\$suffix"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
dd if=/dev/zero of="$work/invalid-Factory.bin" bs=1M count=2 2>/dev/null
cp "$work/invalid-Factory.bin" "$work/valid-Factory.bin"
printf '\201\171\000\000\002\000\000\000\000\001' |
	dd of="$work/valid-Factory.bin" bs=1 conv=notrunc 2>/dev/null
(
	. "$COMMON"
	ws_fail() { exit 1; }
	ws_check_factory "$work/valid-Factory.bin"
) || fail 'target validation rejected valid Factory data'
if (
	. "$COMMON"
	ws_fail() { exit 1; }
	ws_check_factory "$work/invalid-Factory.bin"
); then
	fail 'target validation accepted invalid Factory data'
fi

installer="$TOPDIR/bin/targets/mediatek/filogic/ws1610-transition-installer.tar"
if [ -f "$installer" ]; then
	if "$TOPDIR/scripts/ws1610-transition-test.sh" \
		"$work/invalid-Factory.bin" "$installer" >/dev/null 2>&1; then
		fail 'host round-trip accepted invalid Factory data'
	fi

	mkdir "$work/installer"
	tar -C "$work/installer" -xf "$installer"
	printf 'corruption\n' >> "$work/installer/kernel.lzma"
	tar -C "$work/installer" -cf "$work/corrupt-installer.tar" .
	if "$TOPDIR/scripts/ws1610-transition-test.sh" \
		"$work/valid-Factory.bin" "$work/corrupt-installer.tar" >/dev/null 2>&1; then
		fail 'host round-trip accepted a corrupt installer manifest'
	fi
fi

git -C "$TOPDIR" diff --check HEAD
git -C "$TOPDIR" diff --check HEAD^..HEAD
echo 'WS1610 transition smoke checks passed.'
