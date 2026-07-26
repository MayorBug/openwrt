# Huasifei WS1610 one-shot UBI conversion

This is a device-specific transition image for converting either slot of the
vendor NAND layout to the OpenWrt all-in-UBI layout used by the WS1610 support
branch. It does not use UART or TFTP during a normal installation.

The conversion is automatic and replaces the complete vendor NAND layout.
Returning to vendor firmware requires a separate destructive RAM-only restore
and a verified nine-partition vendor backup; it is not an in-place rollback.
Keep the backup, `mtk_uartboot`, and a UART adapter available in case power is
lost after the vendor kernel volume is replaced or NAND formatting begins.


## Files

- `ws1610-vendor-to-ubi.bin`: image flashed from vendor firmware
- `ws1610-ubi-setup-sysupgrade.itb`: temporary setup system with LuCI
- `ws1610-ubi-clean-sysupgrade.itb`: normal all-in-UBI OpenWrt image
- `ws1610-ubi-preloader.bin`: final raw-NAND BL2
- `ws1610-ubi-bl31-uboot.fip`: final OpenWrt U-Boot FIP
- `ws1610-ubi-recovery.itb`: persistent recovery system
- `build-provenance.txt`: exact source revision used for the release
- `sha256sums`: release checksums

The transitional setup system enables two temporary, open networks:

- `OpenWrt-WS1610-2G`
- `OpenWrt-WS1610-5G`

They are only intended to make the first login convenient. Install the clean
sysupgrade with settings reset after confirming the conversion works.

## The two logs in /docs confirm that this image works and is partition invariant

## Build

Build from a clean `ws1610-transition` checkout. The build script uses all
available CPU threads when `JOBS` is not set:

```fish
cd /path/to/openwrt

set build_log ../ws1610-transition-(date +%Y%m%d-%H%M%S).log
env V=s ./scripts/ws1610-transition-build.sh 2>&1 | tee $build_log
set build_status $pipestatus[1]

echo "Build status: $build_status"
echo "Build log: $build_log"
```

If the parallel build fails, rerun it serially. Completed build output will be
reused:

```fish
set serial_log ../ws1610-transition-serial-(date +%Y%m%d-%H%M%S).log
env JOBS=1 V=s ./scripts/ws1610-transition-build.sh 2>&1 | tee $serial_log
set serial_status $pipestatus[1]

echo "Serial build status: $serial_status"
echo "Serial log: $serial_log"
```

For local testing, use the OpenWrt artifacts directly from
`bin/targets/mediatek/filogic/`. The vendor-flashable image is:

```text
openwrt-mediatek-filogic-huasifei_ws1610-transition-vendor-to-ubi.bin
```

The staging and converter FITs are emitted alongside it. Release archives and
shorter filenames are packaging conveniences and are not required for local
hardware testing.

Every push to `ws1610-transition` also builds the same release archive in
GitHub Actions. A successful build publishes a prerelease for that exact
commit under the fork's Releases page. Release assets do not use the
short-lived workflow-artifact retention period. Download the release archive
and its detached checksum from the Releases page, then verify both the
published checksum and embedded source provenance before use.

## Manual vendor backup

To backup, connect to the vendor firmware at
`192.168.88.1` over SSH and run:

```sh
backup=/tmp/ws1610-backup
parts='BL2 u-boot-env Factory FIP woem ubi ubi2 wtinfo nvram'

mkdir -p "$backup" || exit 1
cat /proc/mtd > "$backup/proc-mtd.txt"
ubus call system board > "$backup/system-board.json"

for part in $parts; do
	mtd dump "$part" > "$backup/$part.bin" || exit 1
done

(cd "$backup" && sha256sum *.bin > sha256sums) || exit 1
wc -c "$backup"/*.bin
```

Verify that all nine files are present and have these exact sizes:

| File | Size |
| --- | ---: |
| `BL2.bin` | 1,048,576 bytes |
| `u-boot-env.bin` | 524,288 bytes |
| `Factory.bin` | 2,097,152 bytes |
| `FIP.bin` | 2,097,152 bytes |
| `woem.bin` | 655,360 bytes |
| `ubi.bin` | 117,440,512 bytes |
| `ubi2.bin` | 117,440,512 bytes |
| `wtinfo.bin` | 393,216 bytes |
| `nvram.bin` | 393,216 bytes |

The expected total is 242,089,984 bytes. Copy the complete directory off the
router and verify `sha256sums` before installing the transition image. Do not
continue with the only copy in `/tmp`.

From the host:

```fish
scp -O -r root@192.168.88.1:/tmp/ws1610-backup .
cd ws1610-backup
sha256sum -c sha256sums
cd ..
```

## Installation

Extract the release archive and verify its checksums:

```fish
cd /path/to/extracted/ws1610-transition-release
sha256sum -c sha256sums
```

Select the vendor transition image, upload it to the vendor firmware, and
compare the complete local and remote hashes:

```fish
set transition_image ws1610-vendor-to-ubi.bin
sha256sum $transition_image
scp -O $transition_image root@192.168.88.1:/tmp/ws1610-vendor-to-ubi.bin
ssh root@192.168.88.1 'sha256sum /tmp/ws1610-vendor-to-ubi.bin'
```

```fish
ssh root@192.168.88.1 'sysupgrade -n -F /tmp/ws1610-vendor-to-ubi.bin'
```

The SSH connection closing after sysupgrade starts is expected. Do not retry
the command or remove power.

The image works regardless of which vendor slot is active. The vendor upgrade
writes and boots its selected target slot. Its `kernel` volume contains a
self-contained staging initramfs, so Linux never mounts `rootfs` from either
vendor slot. The staging system attaches both vendor UBI partitions and selects
the only one containing a unique validated `installer` volume and its matching
`kernel` volume. It rejects a missing or ambiguous installer instead of
guessing, and never changes the vendor slot selector.

Do not remove power after flashing. The following steps happen automatically:

1. The staging initramfs validates the exact vendor layout and locates the
   unique transition payload in either `ubi` or `ubi2`.
2. It reads and validates the complete 2 MiB Factory partition in RAM.
3. It assembles and verifies a device-specific conversion FIT.
4. It replaces only the detected transition slot's `kernel` volume and reboots.
5. Vendor U-Boot loads that FIT into RAM using its NMBM/UBI support.
6. The RAM-only converter verifies every embedded file, formats the final UBI,
   then writes and reads back `factory`, `fip`, `recovery`, and `fit`.
7. The converter writes and verifies final BL2 last.
8. The final, NMBM-free OpenWrt U-Boot starts without saved environment
   volumes and loads its compiled defaults.
9. `preboot` detects the completed installation, creates `ubootenv` and
   `ubootenv2`, and saves valid redundant environments.
10. Later boots load the saved environment normally.

The converter DT temporarily names the raw format target `ubi-convert` so the
kernel cannot auto-attach it as `ubi` before all RAM and hash checks pass.

Raw `ubiformat` warnings, the vendor UBI bad-block reserve warning, and the
existing non-fatal ramoops message are expected. They do not indicate a failed
conversion; the explicit transition verification messages remain authoritative.

## LED status

| Pattern | Meaning |
| --- | --- |
| Wi-Fi LED, slow blink | Assembling and validating the conversion FIT |
| LAN LED, slow blink | RAM converter preflight; NAND is still untouched |
| All six LEDs, fast blink | NAND erase/write is in progress; do not remove power |
| SIM2 LED, rapid blink; others off | Conversion failed and stopped |
| All six LEDs solid for five seconds | Everything verified; rebooting |

LED handling is best-effort. UART remains the authoritative diagnostic output
for development testing.

## Install the clean system

Confirm LuCI and both temporary networks work, then install
`ws1610-ubi-clean-sysupgrade.itb` with settings reset. From SSH:

```fish
ssh root@192.168.1.1 'sysupgrade -n /tmp/ws1610-ubi-clean-sysupgrade.itb'
```

Alternatively, upload it in LuCI and select the option to discard settings.
The clean image uses normal OpenWrt defaults and leaves Wi-Fi disabled.
