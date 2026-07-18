#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

for config in "$repo_root"/config/coreboot-starlabs_*.config; do
	case "$config" in
		*coreboot-starlabs_qemu.config) continue ;;
	esac
	grep -Fx 'CONFIG_SMMSTORE=y' "$config" >/dev/null
	grep -Fx 'CONFIG_USE_UEFI_VARIABLE_STORE=y' "$config" >/dev/null
done

echo "Star Labs board policy tests passed"
