#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
audit="$repo_root/bin/starlabs-fmap-audit.sh"
merge="$repo_root/bin/starlabs-merge-coreboot.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/tool path"
fake_cbfstool="$tmpdir/tool path/cbfstool"
cat > "$fake_cbfstool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

image=$1
shift
command=$1
shift
case "$command" in
	layout)
		if [ "${FAKE_MIGRATION:-0}" = 1 ]; then
			case "$(basename "$image")" in
				reference.rom)
					cat <<'LAYOUT'
'SI_ALL' (read-only, size 16777216, offset 0)
'EC' (size 131072, offset 0)
'RW_MRC_CACHE' (size 65536, offset 131072)
'SMMSTORE' (size 524288, offset 196608)
'CONSOLE' (size 131072, offset 720896)
'FMAP' (read-only, size 4096, offset 851968)
'COREBOOT' (CBFS, size 15921152, offset 856064)
LAYOUT
					;;
				*)
					cat <<'LAYOUT'
'SI_ALL' (read-only, size 16777216, offset 0)
'EC' (size 131072, offset 0)
'RW_MRC_CACHE' (size 65536, offset 131072)
'SMMSTORE' (size 524288, offset 196608)
'CONSOLE' (size 131072, offset 720896)
'PSP_NVRAM' (preserve, size 131072, offset 851968)
'FMAP' (read-only, size 4096, offset 983040)
'COREBOOT' (CBFS, size 15790080, offset 987136)
LAYOUT
					;;
			esac
		else
			cat <<'LAYOUT'
'../../outside' (size 1, offset 0)
'COREBOOT' (CBFS, size 1, offset 1)
LAYOUT
		fi
		;;
	read)
		output=
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-f) output=$2; shift 2 ;;
				*) shift ;;
			esac
		done
		[ -n "$output" ]
		printf 'x' > "$output"
		printf '%s\n' "$output" >> "$FAKE_CBFSTOOL_LOG"
		;;
	*)
		echo "Unexpected command: $command" >&2
		exit 1
		;;
esac
EOF
chmod +x "$fake_cbfstool"

rom="$tmpdir/input.rom"
report="$tmpdir/report.txt"
stdout="$tmpdir/stdout.txt"
tool_log="$tmpdir/cbfstool.log"
printf 'rom' > "$rom"

FAKE_CBFSTOOL_LOG="$tool_log" "$audit" \
	--rom "$rom" \
	--cbfstool "$fake_cbfstool" \
	--expected-size 3 \
	--report "$report" > "$stdout"
cmp "$stdout" "$report"

expected_index=0
region_dir=
temp_root=$(realpath -m "${TMPDIR:-/tmp}")
while IFS= read -r output; do
	expected=$(printf 'region-%04d.bin' "$expected_index")
	[ "$(basename "$output")" = "$expected" ]
	output_real=$(realpath -m "$output")
	case "$output_real" in
		"$temp_root"/tmp.*/*) ;;
		*) echo "Region output escaped its temporary directory: $output" >&2; exit 1 ;;
	esac
	if [ -z "$region_dir" ]; then
		region_dir=$(dirname "$output_real")
	else
		[ "$(dirname "$output_real")" = "$region_dir" ]
	fi
	expected_index=$((expected_index + 1))
done < "$tool_log"
[ "$expected_index" -eq 2 ]

if FAKE_CBFSTOOL_LOG="$tool_log" "$audit" \
	--rom "$rom" \
	--cbfstool "$fake_cbfstool" \
	--report /dev/full >/dev/null 2>&1; then
	echo "Audit succeeded despite a failed report write" >&2
	exit 1
fi

reference="$tmpdir/reference.rom"
heads="$tmpdir/heads.rom"
output_alias="$tmpdir/output.rom"
printf 'reference' > "$reference"
printf 'new heads' > "$heads"
ln "$heads" "$output_alias"
heads_hash=$(sha256sum "$heads")
if "$merge" \
	--reference "$reference" \
	--heads "$heads" \
	--output "$output_alias" \
	--cbfstool "$fake_cbfstool" \
	--force >/dev/null 2>&1; then
	echo "Merge accepted an output hard-linked to an input" >&2
	exit 1
fi
[ "$(sha256sum "$heads")" = "$heads_hash" ]

truncate -s 16777216 "$reference"
truncate -s 16777216 "$heads"
printf 'per-unit-reference' | dd of="$reference" conv=notrunc status=none
printf 'heads-coreboot-tail' | dd of="$heads" bs=1 seek=987136 conv=notrunc status=none
dd if=/dev/zero bs=4096 count=32 status=none |
	tr '\000' '\377' |
	dd of="$heads" bs=4096 seek=208 conv=notrunc status=none

migrated="$tmpdir/migrated.rom"
FAKE_MIGRATION=1 "$merge" \
	--migrate-cezanne-2607 \
	--reference "$reference" \
	--heads "$heads" \
	--output "$migrated" \
	--cbfstool "$fake_cbfstool" >/dev/null
cmp -n 851968 "$reference" "$migrated"
cmp \
	<(dd if="$heads" bs=4096 skip=208 status=none) \
	<(dd if="$migrated" bs=4096 skip=208 status=none)

printf '\000' | dd of="$heads" bs=1 seek=$((0xd0000 + 17)) conv=notrunc status=none
if FAKE_MIGRATION=1 "$merge" \
	--migrate-cezanne-2607 \
	--reference "$reference" \
	--heads "$heads" \
	--output "$tmpdir/rejected.rom" \
	--cbfstool "$fake_cbfstool" >/dev/null 2>&1; then
	echo "Cezanne migration accepted initialized PSP_NVRAM data" >&2
	exit 1
fi

echo "Star Labs FMAP helper tests passed"
