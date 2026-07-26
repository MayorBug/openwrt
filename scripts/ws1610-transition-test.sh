#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

TOPDIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
FACTORY="${1:?usage: $0 Factory.bin installer.tar}"
INSTALLER="${2:?usage: $0 Factory.bin installer.tar}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

[ "$(wc -c < "$FACTORY")" -eq 2097152 ] || { echo 'Factory must be 2 MiB.' >&2; exit 1; }
[ "$(od -An -tx1 -N2 "$FACTORY" | tr -d ' \n')" = 8179 ] || {
	echo 'Factory lacks the MT7981 EEPROM marker.' >&2
	exit 1
}
set -- $(od -An -tu1 -j4 -N6 "$FACTORY")
[ "$#" -eq 6 ] || { echo 'Factory base MAC is unreadable.' >&2; exit 1; }
[ $(( $1 % 2 )) -eq 0 ] || { echo 'Factory base MAC is multicast.' >&2; exit 1; }
[ "$*" != '0 0 0 0 0 0' ] || { echo 'Factory base MAC is all zeroes.' >&2; exit 1; }
[ "$*" != '255 255 255 255 255 255' ] || { echo 'Factory base MAC is erased.' >&2; exit 1; }
mkdir -p "$WORK/installer" "$WORK/initroot" \
	"$WORK/payload/usr/share/ws1610-converter"
tar -C "$WORK/installer" -xf "$INSTALLER"
(
	cd "$WORK/installer"
	sha256sum -c manifest.sha256
)
for file in final-bl2.bin final-fip.bin recovery.itb setup.itb; do
	cp "$WORK/installer/$file" \
		"$WORK/payload/usr/share/ws1610-converter/$file"
done
cp "$FACTORY" "$WORK/payload/usr/share/ws1610-converter/Factory.bin"
(
	cd "$WORK/payload/usr/share/ws1610-converter"
	sha256sum Factory.bin final-bl2.bin final-fip.bin recovery.itb setup.itb \
		> payload.sha256
)
(
	cd "$WORK/payload"
	find . -print | sort | cpio -o -H newc
) > "$WORK/payload.cpio"
(
	cd "$WORK/initroot"
	cpio -id --quiet < "$WORK/installer/initrd-base.cpio"
	cpio -idu --quiet < "$WORK/payload.cpio"
	find . -print | sort | cpio -o -H newc --quiet
) > "$WORK/initrd.cpio"
gzip -9 < "$WORK/initrd.cpio" > "$WORK/initrd.cpio.gz"
for file in kernel.lzma converter.dtb converter.its; do
	cp "$WORK/installer/$file" "$WORK/$file"
done

MKIMAGE="$TOPDIR/staging_dir/host/bin/mkimage"
DUMPIMAGE="$(find "$TOPDIR/build_dir/host" -type f \
	-path '*/tools/dumpimage' -perm -u+x | head -n 1)"
DTC="$(find "$TOPDIR/build_dir" -type f -path '*/scripts/dtc/dtc' -perm -u+x | head -n 1)"
[ -x "$MKIMAGE" ] && [ -x "$DUMPIMAGE" ] && [ -x "$DTC" ] || {
	echo 'Build host mkimage, dumpimage and dtc first.' >&2
	exit 1
}
(
	cd "$WORK"
	PATH="$(dirname "$DTC"):$PATH" "$MKIMAGE" -f converter.its converter.itb
)
"$DUMPIMAGE" -T flat_dt -p 1 -o "$WORK/roundtrip.cpio.gz" "$WORK/converter.itb"
mkdir "$WORK/roundtrip"
(
	cd "$WORK/roundtrip"
	gzip -dc "$WORK/roundtrip.cpio.gz" | cpio -id --quiet
)
cmp "$FACTORY" "$WORK/roundtrip/usr/share/ws1610-converter/Factory.bin"
echo 'Factory survived conversion FIT assembly byte-for-byte.'
