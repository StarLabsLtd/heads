#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

grep -Fx 'CONFIG_PCIUTILS=y' "$repo_root/boards/starlabs/common.config" >/dev/null
grep -Fx 'CONFIG_PCIUTILS=n' "$repo_root/boards/starlabs/compact.config" >/dev/null
grep -Fx 'CONFIG_PCIUTILS_LIB_ONLY=y' \
	"$repo_root/boards/starlabs/compact.config" >/dev/null
grep -Fx 'modules-$(CONFIG_PCIUTILS_LIB_ONLY) += pciutils' \
	"$repo_root/modules/pciutils" >/dev/null
grep -Fx 'CONFIG_CPU_SUP_AMD=y' "$repo_root/config/linux-starlabs-common.config" >/dev/null

for config in "$repo_root"/config/coreboot-starlabs_*.config; do
	case "$config" in
		*coreboot-starlabs_qemu.config) continue ;;
	esac
	grep -Fx 'CONFIG_SMMSTORE=y' "$config" >/dev/null
	grep -Fx 'CONFIG_USE_UEFI_VARIABLE_STORE=y' "$config" >/dev/null
done

intel_boards=(
	adl_horizon byte_adl byte_twl labtop_cml labtop_kbl lite_adl
	starbook_adl starbook_adl_n starbook_mtl starbook_rpl starbook_tgl
	starfighter_mtl starfighter_rpl
)

for board in "${intel_boards[@]}"; do
	config="$repo_root/config/coreboot-starlabs_${board}.config"
	grep -Fx 'CONFIG_BOOTMEDIA_LOCK_CONTROLLER=y' "$config" >/dev/null
	grep -Fx 'CONFIG_BOOTMEDIA_LOCK_WHOLE_RO=y' "$config" >/dev/null
	grep -Fx '# CONFIG_BOOTMEDIA_SMM_BWP is not set' "$config" >/dev/null
	grep -Fx '# CONFIG_INTEL_CHIPSET_LOCKDOWN is not set' "$config" >/dev/null
	grep -Fx 'CONFIG_SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM=y' "$config" >/dev/null
	grep -Eq '^include .*boards/starlabs/(compact|physical)-intel\.config$' \
		"$repo_root/boards/starlabs_${board}/starlabs_${board}.config"
done

for config in \
	"$repo_root/config/coreboot-starlabs_byte_cezanne.config" \
	"$repo_root/config/coreboot-starlabs_starbook_cezanne.config" \
	"$repo_root/config/coreboot-starlabs_lite_glk.config" \
	"$repo_root/config/coreboot-starlabs_lite_glkr.config"; do
	if grep -Eq '^CONFIG_(SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM|BOOTMEDIA_LOCK_CONTROLLER)=y$' \
		"$config"; then
		echo "Non-update target inherited Intel deferred locking: $config" >&2
		exit 1
	fi
done

for overlay in compact-intel physical-intel; do
	grep -Fx 'CONFIG_IO386=y' \
		"$repo_root/boards/starlabs/${overlay}.config" >/dev/null
	grep -Fx 'export CONFIG_FINALIZE_PLATFORM_LOCKING=y' \
		"$repo_root/boards/starlabs/${overlay}.config" >/dev/null
done

test -f "$repo_root/patches/coreboot-starlabs_2607/0004-soc-intel-lockdown-allow-SPI-locking-in-SMM.patch"

echo "Star Labs board policy tests passed"
