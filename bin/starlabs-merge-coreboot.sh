#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: starlabs-merge-coreboot.sh --reference BACKUP --heads HEADS_ROM --output ROM [OPTIONS]

Copy only the FMAP COREBOOT region from a Heads image into a full-chip,
per-unit reference backup. All bytes outside COREBOOT must remain identical.

Options:
  --cbfstool PATH  cbfstool binary (default: cbfstool)
  --force          replace an existing output file
USAGE
}

REFERENCE=
HEADS_ROM=
OUTPUT=
CBFSTOOL=cbfstool
FORCE=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--reference) REFERENCE=$2; shift 2 ;;
		--heads) HEADS_ROM=$2; shift 2 ;;
		--output) OUTPUT=$2; shift 2 ;;
		--cbfstool) CBFSTOOL=$2; shift 2 ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

for input in "$REFERENCE" "$HEADS_ROM"; do
	[ -n "$input" ] || { usage >&2; exit 2; }
	[ -f "$input" ] || { echo "Input not found: $input" >&2; exit 1; }
done
[ -n "$OUTPUT" ] || { usage >&2; exit 2; }
reference_real=$(realpath "$REFERENCE")
heads_real=$(realpath "$HEADS_ROM")
output_real=$(realpath -m "$OUTPUT")
if [ "$output_real" = "$reference_real" ] || [ "$output_real" = "$heads_real" ]; then
	echo "Output must not overwrite either input: $OUTPUT" >&2
	exit 1
fi
if [ -e "$OUTPUT" ] && [ "$FORCE" -ne 1 ]; then
	echo "Output already exists (use --force): $OUTPUT" >&2
	exit 1
fi
command -v "$CBFSTOOL" >/dev/null 2>&1 || { echo "cbfstool not found: $CBFSTOOL" >&2; exit 1; }

reference_size=$(stat -c '%s' "$REFERENCE")
heads_size=$(stat -c '%s' "$HEADS_ROM")
if [ "$reference_size" -ne "$heads_size" ]; then
	echo "Image size mismatch: reference=$reference_size heads=$heads_size" >&2
	exit 1
fi

layout_tuple() {
	"$CBFSTOOL" "$1" layout -w | awk -F'[ (),]+' '
		/^'"'"'COREBOOT'"'"'/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "size") size = $(i + 1)
				if ($i == "offset") offset = $(i + 1)
			}
		}
		END { if (size != "" && offset != "") print size, offset }
	'
}

layout_regions() {
	"$CBFSTOOL" "$1" layout -w | sed -n "/^'/p"
}

reference_regions=$(layout_regions "$REFERENCE")
heads_regions=$(layout_regions "$HEADS_ROM")
if [ "$reference_regions" != "$heads_regions" ]; then
	echo "FMAP layout mismatch between reference and Heads images" >&2
	diff -u <(printf '%s\n' "$reference_regions") <(printf '%s\n' "$heads_regions") >&2 || true
	exit 1
fi

read -r coreboot_size coreboot_offset < <(layout_tuple "$REFERENCE")
read -r heads_coreboot_size heads_coreboot_offset < <(layout_tuple "$HEADS_ROM")
if [ -z "${coreboot_size:-}" ] || [ -z "${heads_coreboot_size:-}" ]; then
	echo "Both images must contain an FMAP COREBOOT region" >&2
	exit 1
fi
if [ "$coreboot_size $coreboot_offset" != "$heads_coreboot_size $heads_coreboot_offset" ]; then
	echo "COREBOOT layout mismatch" >&2
	echo "reference: size=$coreboot_size offset=$coreboot_offset" >&2
	echo "heads:     size=$heads_coreboot_size offset=$heads_coreboot_offset" >&2
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
coreboot_image="$tmpdir/COREBOOT.bin"
verified_image="$tmpdir/COREBOOT.verified.bin"

"$CBFSTOOL" "$HEADS_ROM" read -r COREBOOT -f "$coreboot_image" >/dev/null
cp "$REFERENCE" "$OUTPUT"
"$CBFSTOOL" "$OUTPUT" write -F -r COREBOOT -f "$coreboot_image" >/dev/null
"$CBFSTOOL" "$OUTPUT" read -r COREBOOT -f "$verified_image" >/dev/null
cmp "$coreboot_image" "$verified_image"

# Verify the immutable prefix and suffix independently. COREBOOT is normally
# the final region, but the suffix check keeps this valid for other layouts.
if [ "$coreboot_offset" -gt 0 ]; then
	cmp -n "$coreboot_offset" "$REFERENCE" "$OUTPUT"
fi
coreboot_end=$((coreboot_offset + coreboot_size))
suffix_size=$((reference_size - coreboot_end))
if [ "$suffix_size" -gt 0 ]; then
	cmp \
		<(dd if="$REFERENCE" bs=1 skip="$coreboot_end" status=none) \
		<(dd if="$OUTPUT" bs=1 skip="$coreboot_end" status=none)
fi

echo "Merged COREBOOT: offset=$coreboot_offset size=$coreboot_size"
printf 'Reference SHA256: '
sha256sum "$REFERENCE" | awk '{print $1}'
printf 'Heads COREBOOT SHA256: '
sha256sum "$coreboot_image" | awk '{print $1}'
printf 'Output SHA256: '
sha256sum "$OUTPUT" | awk '{print $1}'
echo "Verified: every byte outside FMAP COREBOOT is identical to the reference."
