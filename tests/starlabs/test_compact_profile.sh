#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
compact="$repo_root/boards/starlabs/compact.config"

required_compact=(
	CONFIG_BUSYBOX_COMPACT=y
	CONFIG_PCIUTILS=n
	CONFIG_PCIUTILS_LIB_ONLY=y
)

for setting in "${required_compact[@]}"; do
	grep -Fx "$setting" "$compact" >/dev/null
done

# These proof gates come from physical.config/common.config and must not be
# disabled by the compact overlay.
for setting in \
	CONFIG_FLASHPROG=y \
	CONFIG_GPG2=y \
	CONFIG_KEXEC=y \
	CONFIG_TPM2_TSS=y \
	CONFIG_OPENSSL=y \
	CONFIG_CAIRO=y \
	CONFIG_FBWHIPTAIL=y; do
	if grep -Fx "${setting%=y}=n" "$compact" >/dev/null; then
		echo "Compact profile disabled required gate: $setting" >&2
		exit 1
	fi
done

for board in byte_cezanne starbook_cezanne; do
	grep -Eq '^include .*boards/starlabs/compact\.config$' \
		"$repo_root/boards/starlabs_${board}/starlabs_${board}.config"
done

for board in labtop_kbl lite_glk lite_glkr; do
	grep -Eq '^include .*boards/starlabs/compact-analysis-intel\.config$' \
		"$repo_root/boards/starlabs_${board}/starlabs_${board}.config"
done

for board in labtop_kbl lite_glk lite_glkr; do
	make -s -f - repo_root="$repo_root" board="$board" <<'MAKEFILE'
pwd := $(repo_root)
include $(repo_root)/boards/starlabs_$(board)/starlabs_$(board).config
.PHONY: all
all:
	@test -z "$(CONFIG_FLASH_OPTIONS)"
	@test -z "$(CONFIG_FLASH_READ_OPTIONS)"
	@test "$(CONFIG_CBFS_VIA_FLASHPROG)" = n
	@! env | grep -q '^CONFIG_FLASH_OPTIONS='
	@! env | grep -q '^CONFIG_FLASH_READ_OPTIONS='
MAKEFILE
done

grep -F 'if [ -x /bin/qrenc ]; then' \
	"$repo_root/initrd/bin/kexec-boot.sh" >/dev/null

grep -F 'busybox_module := busybox-compact' \
	"$repo_root/modules/busybox" >/dev/null
grep -F '$(busybox_module)_patch_name_override := busybox-1.36.1' \
	"$repo_root/modules/busybox" >/dev/null
grep -F '$(busybox_module)_depends := $(musl_dep)' \
	"$repo_root/modules/busybox" >/dev/null
grep -F "CONFIG_LSPCI=y" "$repo_root/modules/busybox" >/dev/null
for applet in ARP I2CGET PING TLS WGET UDHCPC; do
	grep -qw "$applet" "$repo_root/modules/busybox"
done

grep -F 'zstd_configure := $(MAKE) -C programs clean' \
	"$repo_root/modules/zstd" >/dev/null

for library in cairo libpng openssl pixman zlib; do
	grep -F 'test ! -f Makefile || $(MAKE) clean' \
		"$repo_root/modules/$library" >/dev/null
	map="$repo_root/config/runtime-symbols/$library.map"
	test -s "$map"
	grep -F 'global:' "$map" >/dev/null
	grep -F 'local:' "$map" >/dev/null
	grep -F '*;' "$map" >/dev/null
	grep -F "config/runtime-symbols/$library.map" \
		"$repo_root/modules/$library" >/dev/null
done

grep -qw EVP_sha256 "$repo_root/config/runtime-symbols/openssl.map"
grep -qw cairo_show_text "$repo_root/config/runtime-symbols/cairo.map"
grep -qw png_read_image "$repo_root/config/runtime-symbols/libpng.map"
grep -Fq "libpng.vers: \$(pwd)/config/runtime-symbols/libpng.map" \
	"$repo_root/modules/libpng"
grep -Fq 'install-data-hook \' "$repo_root/modules/libpng"
grep -Fq 'install-exec-hook \' "$repo_root/modules/libpng"
grep -qw pixman_image_composite32 "$repo_root/config/runtime-symbols/pixman.map"
grep -qw inflate "$repo_root/config/runtime-symbols/zlib.map"

echo "Star Labs compact profile tests passed"
