#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
audit="$repo_root/bin/starlabs-fmap-audit.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/tool path"
fake_cbfstool="$tmpdir/tool path/cbfstool"
cat > "$fake_cbfstool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

shift
command=$1
shift
case "$command" in
	layout)
		cat <<'LAYOUT'
'../../outside' (size 1, offset 0)
'COREBOOT' (CBFS, size 1, offset 1)
LAYOUT
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

echo "Star Labs FMAP helper tests passed"
