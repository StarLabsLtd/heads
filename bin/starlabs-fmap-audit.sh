#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: starlabs-fmap-audit.sh --rom ROM [OPTIONS]

Audit image size, FMAP regions, region hashes, and an optional Intel IFD.

Options:
  --cbfstool PATH       cbfstool binary (default: cbfstool)
  --ifdtool PATH        ifdtool binary (default: ifdtool)
  --ifd-platform NAME   ifdtool platform, for example mtl, adl, or glk
  --expected-size SIZE  required image size in decimal or 0x notation
  --report PATH         also write the report to PATH
USAGE
}

ROM=
CBFSTOOL=cbfstool
IFDTOOL=ifdtool
IFD_PLATFORM=
EXPECTED_SIZE=
REPORT=

while [ "$#" -gt 0 ]; do
	case "$1" in
		--rom) ROM=$2; shift 2 ;;
		--cbfstool) CBFSTOOL=$2; shift 2 ;;
		--ifdtool) IFDTOOL=$2; shift 2 ;;
		--ifd-platform) IFD_PLATFORM=$2; shift 2 ;;
		--expected-size) EXPECTED_SIZE=$2; shift 2 ;;
		--report) REPORT=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -n "$ROM" ] || { usage >&2; exit 2; }
[ -f "$ROM" ] || { echo "ROM not found: $ROM" >&2; exit 1; }
command -v "$CBFSTOOL" >/dev/null 2>&1 || { echo "cbfstool not found: $CBFSTOOL" >&2; exit 1; }

if [ -n "$REPORT" ]; then
	mkdir -p "$(dirname "$REPORT")"
	exec > >(tee "$REPORT")
fi

rom_size=$(stat -c '%s' "$ROM")
if [ -n "$EXPECTED_SIZE" ] && [ "$rom_size" -ne "$((EXPECTED_SIZE))" ]; then
	echo "Image size mismatch: got $rom_size, expected $((EXPECTED_SIZE))" >&2
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "ROM: $ROM"
echo "SIZE: $rom_size"
printf 'SHA256: '
sha256sum "$ROM" | awk '{print $1}'
echo
echo "FMAP layout:"
layout=$($CBFSTOOL "$ROM" layout -w)
printf '%s\n' "$layout"

echo
echo "FMAP region SHA256:"
while IFS= read -r region; do
	region_file="$tmpdir/$region.bin"
	$CBFSTOOL "$ROM" read -r "$region" -f "$region_file" >/dev/null
	printf '%-20s %10s  ' "$region" "$(stat -c '%s' "$region_file")"
	sha256sum "$region_file" | awk '{print $1}'
done < <(printf '%s\n' "$layout" | sed -n "s/^'\([^']*\)'.*/\1/p")

if [ -n "$IFD_PLATFORM" ]; then
	command -v "$IFDTOOL" >/dev/null 2>&1 || { echo "ifdtool not found: $IFDTOOL" >&2; exit 1; }
	echo
	echo "Intel flash descriptor ($IFD_PLATFORM):"
	$IFDTOOL --platform "$IFD_PLATFORM" --dump "$ROM"
fi
