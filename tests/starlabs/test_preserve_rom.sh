#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
payload=/tmp/rom.$$
trap 'rm -rf "$tmpdir" "$payload"' EXIT

TRACE_STACK=test
# shellcheck source=../../initrd/etc/functions.sh
. "$repo_root/initrd/etc/functions.sh"

TRACE_FUNC() { :; }
DEBUG() { :; }
STATUS() { :; }
STATUS_OK() { :; }
DIE() {
	printf '%s\n' "$*" >> "$tmpdir/die.log"
	return 1
}

cbfs() {
	printf '%s\n' "$*" >> "$tmpdir/cbfs.log"
	case " $* " in
		*" -l "*)
			[ "${CBFS_LIST_FAIL:-0}" = 1 ] && return 1
			printf '%s\n' \
				'heads/initrd/.gnupg/pubring.kbx' \
				'heads/initrd/etc/config.user'
			;;
		*" -r heads/initrd/.gnupg/pubring.kbx "*)
			printf 'keyring'
			;;
		*" -r heads/initrd/etc/config.user "*)
			printf 'config'
			;;
		*) return 1 ;;
	esac
}

cbfs.sh() {
	printf '%s\n' "$*" >> "$tmpdir/cbfs-sh.log"
	case " $* " in
		*" -l "*) return 0 ;;
		*" -a heads/initrd/.gnupg/pubring.kbx "*)
			[ "$(cat "$payload")" = keyring ]
			;;
		*" -a heads/initrd/etc/config.user "*)
			[ "$(cat "$payload")" = config ]
			;;
		*) return 1 ;;
	esac
}

CONFIG_CBFS_VIA_FLASHPROG=y
CBFS_CURRENT_ROM="$tmpdir/cbfs-init.rom"
new_rom="$tmpdir/new.rom"
printf 'current' > "$CBFS_CURRENT_ROM"
printf 'new' > "$new_rom"

preserve_rom "$new_rom"

[ "$(wc -l < "$tmpdir/cbfs.log")" -eq 3 ]
while IFS= read -r invocation; do
	case " $invocation " in
		*" -o $CBFS_CURRENT_ROM "*) ;;
		*) echo "Current CBFS access omitted the flash snapshot: $invocation" >&2; exit 1 ;;
	esac
done < "$tmpdir/cbfs.log"
[ "$(grep -c ' -a heads/' "$tmpdir/cbfs-sh.log")" -eq 2 ]

rm -f "$CBFS_CURRENT_ROM"
: > "$tmpdir/cbfs.log"
if preserve_rom "$new_rom"; then
	echo "Preservation succeeded without a current-firmware snapshot" >&2
	exit 1
fi
[ ! -s "$tmpdir/cbfs.log" ]
grep -Fx 'preserve_rom: current firmware readback is unavailable' "$tmpdir/die.log" >/dev/null

printf 'current' > "$CBFS_CURRENT_ROM"
CBFS_LIST_FAIL=1
for CONFIG_CBFS_VIA_FLASHPROG in y n; do
	if preserve_rom "$new_rom"; then
		echo "Preservation succeeded after a CBFS listing failure" >&2
		exit 1
	fi
done
[ "$(grep -cFx 'preserve_rom: failed to list current firmware CBFS' "$tmpdir/die.log")" -eq 2 ]
[ ! -e "/tmp/cbfs-list.$$" ]

echo "Star Labs CBFS preservation tests passed"
