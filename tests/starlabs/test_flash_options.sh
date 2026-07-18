#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

flash_rom_source=$(awk '
	/^flash_rom\(\) \{/ { capture = 1 }
	capture { print }
	capture && /^}/ { exit }
' "$repo_root/initrd/bin/flash.sh")
eval "$flash_rom_source"

read_tool() {
	printf '%s\n' "$*" > "$tmpdir/invocation"
}
write_tool() {
	printf '%s\n' "$*" > "$tmpdir/invocation"
}
recovery() {
	echo "Unexpected recovery: $*" >&2
	return 1
}

READ=1
CONFIG_FLASH_OPTIONS='write_tool --write-policy'
CONFIG_FLASH_READ_OPTIONS='read_tool --read-policy'
flash_rom "$tmpdir/rom"
grep -Fx -- "--read-policy -r $tmpdir/rom" "$tmpdir/invocation" >/dev/null

unset CONFIG_FLASH_READ_OPTIONS
flash_rom "$tmpdir/rom"
grep -Fx -- "--write-policy -r $tmpdir/rom" "$tmpdir/invocation" >/dev/null

grep -Fx \
	'export CONFIG_FLASH_OPTIONS="flashprog --progress --programmer internal --fmap -i COREBOOT"' \
	"$repo_root/boards/starlabs/physical.config" >/dev/null
grep -Fx \
	'export CONFIG_FLASH_READ_OPTIONS="flashprog --progress --programmer internal --fmap -i COREBOOT -i FMAP"' \
	"$repo_root/boards/starlabs/physical.config" >/dev/null

echo "Star Labs flash option tests passed"
