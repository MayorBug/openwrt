#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

TOPDIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
TARGET_DIR="$TOPDIR/bin/targets/mediatek/filogic"
SOURCE_STATUS="$(git -C "$TOPDIR" status --porcelain --untracked-files=normal)"
[ -z "$SOURCE_STATUS" ] || {
	echo 'Refusing to build a release archive from a dirty source tree.' >&2
	exit 1
}
SOURCE_COMMIT="$(git -C "$TOPDIR" rev-parse HEAD)"
SOURCE_BRANCH="$(git -C "$TOPDIR" branch --show-current)"
SOURCE_REMOTE="$(git -C "$TOPDIR" remote get-url origin 2>/dev/null || echo unknown)"
WORK="$(mktemp -d "$TOPDIR/tmp/ws1610-transition.XXXXXX")"
ORIGINAL_CONFIG="$WORK/config.original"
RELEASE="$WORK/release"
HAD_CONFIG=0

[ -f "$TOPDIR/Makefile" ] || { echo 'Run this script from an OpenWrt tree.' >&2; exit 1; }
if [ -f "$TOPDIR/.config" ]; then
	cp "$TOPDIR/.config" "$ORIGINAL_CONFIG"
	HAD_CONFIG=1
fi

cleanup() {
	if [ "$HAD_CONFIG" -eq 1 ] && [ -f "$ORIGINAL_CONFIG" ]; then
		cp "$ORIGINAL_CONFIG" "$TOPDIR/.config"
	else
		rm -f "$TOPDIR/.config"
	fi
	[ ! -d "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_config() {
	local profile="$1" setup="${2:-0}" compression=XZ
	case "$profile" in
	huasifei_ws1610-converter) compression=GZIP ;;
	esac
	cat > "$TOPDIR/.config" <<-EOF
	CONFIG_TARGET_mediatek=y
	CONFIG_TARGET_mediatek_filogic=y
	CONFIG_TARGET_mediatek_filogic_DEVICE_$profile=y
	CONFIG_TARGET_ROOTFS_SQUASHFS=y
	CONFIG_TARGET_ROOTFS_INITRAMFS=y
	CONFIG_TARGET_ROOTFS_INITRAMFS_SEPARATE=y
	CONFIG_TARGET_INITRAMFS_COMPRESSION_$compression=y
	EOF
	if [ "$profile" = huasifei_ws1610-ubi ]; then
		echo 'CONFIG_PACKAGE_luci-ssl-openssl=y' >> "$TOPDIR/.config"
	fi
	if [ "$setup" -eq 1 ]; then
		echo 'CONFIG_PACKAGE_ws1610-transition-setup=y' >> "$TOPDIR/.config"
	fi
	make -C "$TOPDIR" defconfig
}

copy_one() {
	local pattern="$1" destination="$2" source
	set -- $TARGET_DIR/$pattern
	[ "$#" -eq 1 ] && [ -f "$1" ] || {
		echo "Expected one artifact matching $pattern" >&2
		exit 1
	}
	source="$1"
	cp "$source" "$destination"
}

reject_envtools() {
	local archive="$1" label="$2"
	if cpio -it < "$archive" 2>/dev/null |
		grep -Eq '(^|/)(fw_printenv|fw_setenv|30_uboot-envtools|05_fw_defaults)$'; then
		echo "$label unexpectedly contains U-Boot environment tools." >&2
		exit 1
	fi
}

echo '==> Building clean all-in-UBI images'
write_config huasifei_ws1610-ubi 0
make -C "$TOPDIR" -j"$JOBS"
mkdir -p "$WORK/final" "$RELEASE"
copy_one '*huasifei_ws1610-ubi-preloader.bin' "$WORK/final/final-bl2.bin"
copy_one '*huasifei_ws1610-ubi-bl31-uboot.fip' "$WORK/final/final-fip.bin"
copy_one '*huasifei_ws1610-ubi-initramfs-recovery.itb' "$WORK/final/recovery.itb"
copy_one '*huasifei_ws1610-ubi-squashfs-sysupgrade.itb' \
	"$RELEASE/ws1610-ubi-clean-sysupgrade.itb"
cp "$WORK/final/final-bl2.bin" "$RELEASE/ws1610-ubi-preloader.bin"
cp "$WORK/final/final-fip.bin" "$RELEASE/ws1610-ubi-bl31-uboot.fip"
cp "$WORK/final/recovery.itb" "$RELEASE/ws1610-ubi-recovery.itb"

echo '==> Building temporary LuCI/open-Wi-Fi setup image'
write_config huasifei_ws1610-ubi 1
make -C "$TOPDIR" -j"$JOBS"
copy_one '*huasifei_ws1610-ubi-squashfs-sysupgrade.itb' \
	"$WORK/final/setup.itb"
cp "$WORK/final/setup.itb" "$RELEASE/ws1610-ubi-setup-sysupgrade.itb"

echo '==> Building RAM-only converter kernel and base initramfs'
write_config huasifei_ws1610-converter 0
make -C "$TOPDIR" -j"$JOBS"
copy_one '*huasifei_ws1610-converter-initramfs-converter.itb' "$WORK/converter.itb"

set -- "$TOPDIR"/build_dir/target-*/linux-mediatek_filogic/linux-*/.config
[ "$#" -eq 1 ] && [ -f "$1" ] || {
	echo 'Expected one generated mediatek/filogic kernel configuration.' >&2
	exit 1
}
grep -qx 'CONFIG_RD_GZIP=y' "$1" || {
	echo 'Converter kernel lacks gzip initramfs support.' >&2
	exit 1
}

DUMPIMAGE="$(find "$TOPDIR/build_dir/host" -type f \
	-path '*/tools/dumpimage' -perm -u+x | head -n 1)"
[ -n "$DUMPIMAGE" ] || { echo 'Host dumpimage was not built.' >&2; exit 1; }

mkdir -p "$WORK/installer"
"$DUMPIMAGE" -T flat_dt -p 0 -o "$WORK/installer/kernel.lzma" "$WORK/converter.itb"
"$DUMPIMAGE" -T flat_dt -p 1 -o "$WORK/initrd.cpio.gz" "$WORK/converter.itb"
"$DUMPIMAGE" -T flat_dt -p 2 -o "$WORK/installer/converter.dtb" "$WORK/converter.itb"
gzip -t "$WORK/initrd.cpio.gz"
gzip -dc "$WORK/initrd.cpio.gz" > "$WORK/installer/initrd-base.cpio"
reject_envtools "$WORK/installer/initrd-base.cpio" 'Converter initramfs'
cp "$TOPDIR/scripts/ws1610-transition/converter.its" "$WORK/installer/converter.its"
cp "$WORK/final/"* "$WORK/installer/"
(
	cd "$WORK/installer"
	sha256sum converter.dtb converter.its final-bl2.bin final-fip.bin \
		initrd-base.cpio kernel.lzma recovery.itb setup.itb > manifest.sha256
	tar -cf "$WORK/ws1610-transition-installer.tar" \
		converter.dtb converter.its final-bl2.bin final-fip.bin \
		initrd-base.cpio kernel.lzma manifest.sha256 recovery.itb setup.itb
)

echo '==> Building the self-contained staging initramfs and vendor image'
write_config huasifei_ws1610-transition 0
rm -f "$TARGET_DIR/"*huasifei_ws1610-transition*vendor-to-ubi.bin \
	"$TARGET_DIR/"*huasifei_ws1610-transition*initramfs-stage.itb \
	"$TARGET_DIR/"*huasifei_ws1610-transition*initramfs-converter.itb \
	"$TARGET_DIR/"*huasifei_ws1610-transition*squashfs-factory.bin
find "$TOPDIR/build_dir" -type f -path '*/tmp/*huasifei_ws1610-transition*vendor-to-ubi.bin' \
	-delete
make -C "$TOPDIR" -j"$JOBS" \
	WS1610_TRANSITION_INSTALLER="$WORK/ws1610-transition-installer.tar"
copy_one '*huasifei_ws1610-transition-initramfs-stage.itb' "$WORK/stage.itb"
"$DUMPIMAGE" -l "$WORK/stage.itb" > "$WORK/stage-fit.txt"
grep -Fq 'Init Ramdisk: initrd-1' "$WORK/stage-fit.txt" || {
	echo 'Staging FIT does not contain an initramfs.' >&2
	exit 1
}
sed -n '/Image 1 (initrd-1)/,/Image 2 (fdt-1)/p' "$WORK/stage-fit.txt" |
	grep -Eq 'Compression:[[:space:]]+uncompressed' || {
	echo 'Staging FIT initramfs lacks uncompressed metadata.' >&2
	exit 1
}
"$DUMPIMAGE" -T flat_dt -p 1 -o "$WORK/stage-initrd.cpio.xz" "$WORK/stage.itb"
xz -t "$WORK/stage-initrd.cpio.xz"
xz -dc "$WORK/stage-initrd.cpio.xz" > "$WORK/stage-initrd.cpio"
reject_envtools "$WORK/stage-initrd.cpio" 'Staging initramfs'
copy_one '*huasifei_ws1610-transition-vendor-to-ubi.bin' \
	"$RELEASE/ws1610-vendor-to-ubi.bin"
cp "$WORK/ws1610-transition-installer.tar" \
	"$TARGET_DIR/ws1610-transition-installer.tar"

magic="$(dd if="$RELEASE/ws1610-vendor-to-ubi.bin" bs=1 skip=65536 \
	count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
[ "$magic" = 55424923 ] || {
	echo 'Transition payload lacks UBI magic after its 64 KiB prefix.' >&2
	exit 1
}

cp "$TOPDIR/docs/ws1610-transition.md" "$RELEASE/README.md"
{
	printf 'source_commit=%s\n' "$SOURCE_COMMIT"
	printf 'source_branch=%s\n' "${SOURCE_BRANCH:-detached}"
	printf 'source_remote=%s\n' "$SOURCE_REMOTE"
} > "$RELEASE/build-provenance.txt"
(
	cd "$RELEASE"
	sha256sum README.md build-provenance.txt \
		ws1610-ubi-bl31-uboot.fip ws1610-ubi-clean-sysupgrade.itb \
		ws1610-ubi-preloader.bin ws1610-ubi-recovery.itb \
		ws1610-ubi-setup-sysupgrade.itb ws1610-vendor-to-ubi.bin \
		> sha256sums
)

OUT="$TARGET_DIR/ws1610-transition-v1-$(printf %.12s "$SOURCE_COMMIT").tar.gz"
tar -C "$RELEASE" -czf "$OUT" .
echo "Created $OUT"
