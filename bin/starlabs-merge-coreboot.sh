#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: starlabs-merge-coreboot.sh --reference BACKUP --heads HEADS_ROM --output ROM [OPTIONS]

Copy only the FMAP COREBOOT region from a Heads image into a full-chip,
per-unit reference backup. All bytes outside COREBOOT must remain identical.

Options:
  --migrate-cezanne-2607
                   replace the old 26.07 Cezanne FMAP/COREBOOT tail with the
                   PSP_NVRAM-aware Heads tail; external programming only
  --cbfstool PATH   cbfstool binary (default: cbfstool)
  --force           replace an existing output file
USAGE
}

REFERENCE=
HEADS_ROM=
OUTPUT=
CBFSTOOL=cbfstool
FORCE=0
MIGRATE_CEZANNE_2607=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--reference) REFERENCE=$2; shift 2 ;;
		--heads) HEADS_ROM=$2; shift 2 ;;
		--output) OUTPUT=$2; shift 2 ;;
		--migrate-cezanne-2607) MIGRATE_CEZANNE_2607=1; shift ;;
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
if [ "$output_real" = "$reference_real" ] || [ "$output_real" = "$heads_real" ] ||
	{ [ -e "$OUTPUT" ] &&
		{ [ "$OUTPUT" -ef "$REFERENCE" ] || [ "$OUTPUT" -ef "$HEADS_ROM" ]; }; }; then
	echo "Output must not overwrite either input: $OUTPUT" >&2
	exit 1
fi
if [ -e "$OUTPUT" ] && [ "$FORCE" -ne 1 ]; then
	echo "Output already exists (use --force): $OUTPUT" >&2
	exit 1
fi
command -v "$CBFSTOOL" >/dev/null 2>&1 || { echo "cbfstool not found: $CBFSTOOL" >&2; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

board_identity() {
	local image=$1
	local label=$2
	local config="$tmpdir/$label.config"
	local identity

	if ! "$CBFSTOOL" "$image" extract -r COREBOOT -n config -f "$config" >/dev/null; then
		echo "Unable to extract coreboot board identity from $label image: $image" >&2
		exit 1
	fi
	identity=$(LC_ALL=C sed -n \
		-e '/^CONFIG_MAINBOARD_VENDOR=/p' \
		-e '/^CONFIG_MAINBOARD_PART_NUMBER=/p' \
		-e '/^CONFIG_MAINBOARD_FAMILY=/p' \
		-e '/^CONFIG_BOARD_STARLABS_.*=y$/p' \
		"$config" | sort)
	if ! grep -q '^CONFIG_MAINBOARD_VENDOR=' <<<"$identity" ||
		! grep -q '^CONFIG_MAINBOARD_PART_NUMBER=' <<<"$identity" ||
		! grep -q '^CONFIG_BOARD_STARLABS_.*=y$' <<<"$identity"; then
		echo "Incomplete coreboot board identity in $label image: $image" >&2
		exit 1
	fi
	printf '%s\n' "$identity"
}

reference_size=$(stat -c '%s' "$REFERENCE")
heads_size=$(stat -c '%s' "$HEADS_ROM")
if [ "$reference_size" -ne "$heads_size" ]; then
	echo "Image size mismatch: reference=$reference_size heads=$heads_size" >&2
	exit 1
fi

reference_identity=$(board_identity "$REFERENCE" reference)
heads_identity=$(board_identity "$HEADS_ROM" heads)
if [ "$reference_identity" != "$heads_identity" ]; then
	echo "Board identity mismatch between reference and Heads images" >&2
	diff -u \
		<(printf '%s\n' "$reference_identity") \
		<(printf '%s\n' "$heads_identity") >&2 || true
	exit 1
fi

canonical_layout() {
	"$CBFSTOOL" "$1" layout -w | sed -n \
		"s/^'\([^']*\)'.*size \([0-9][0-9]*\), offset \([0-9][0-9]*\).*/\1 \3 \2/p"
}

require_layout() {
	local image=$1
	local expected=$2
	local description=$3
	local actual

	actual=$(canonical_layout "$image")
	if [ "$actual" != "$expected" ]; then
		echo "$description layout mismatch: $image" >&2
		diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
		exit 1
	fi
}

require_preserve_region() {
	local image=$1
	local region=$2
	local size=$3
	local offset=$4

	if ! "$CBFSTOOL" "$image" layout -w | grep -Eq \
		"^'${region}' \\(preserve, size ${size}, offset ${offset}\\)$"; then
		echo "$region is not marked preserve: $image" >&2
		exit 1
	fi
}

if [ "$MIGRATE_CEZANNE_2607" -eq 1 ]; then
	image_size=$((16 * 1024 * 1024))
	migration_offset=$((0xd0000))
	psp_nvram_size=$((0x20000))
	block_size=4096

	if [ "$reference_size" -ne "$image_size" ]; then
		echo "Cezanne migration requires two 16 MiB images" >&2
		exit 1
	fi

	old_layout=$(cat <<'EOF'
SI_ALL 0 16777216
EC 0 131072
RW_MRC_CACHE 131072 65536
SMMSTORE 196608 524288
CONSOLE 720896 131072
FMAP 851968 4096
COREBOOT 856064 15921152
EOF
	)
	new_layout=$(cat <<'EOF'
SI_ALL 0 16777216
EC 0 131072
RW_MRC_CACHE 131072 65536
SMMSTORE 196608 524288
CONSOLE 720896 131072
PSP_NVRAM 851968 131072
FMAP 983040 4096
COREBOOT 987136 15790080
EOF
	)
	require_layout "$REFERENCE" "$old_layout" "26.07 Cezanne reference"
	require_layout "$HEADS_ROM" "$new_layout" "PSP_NVRAM-aware Heads"
	require_preserve_region "$HEADS_ROM" PSP_NVRAM \
		"$psp_nvram_size" "$migration_offset"

	psp_nvram="$tmpdir/PSP_NVRAM.bin"
	erased_nvram="$tmpdir/PSP_NVRAM.erased.bin"
	dd if="$HEADS_ROM" of="$psp_nvram" bs="$block_size" \
		skip=$((migration_offset / block_size)) \
		count=$((psp_nvram_size / block_size)) status=none
	dd if=/dev/zero bs="$block_size" count=$((psp_nvram_size / block_size)) status=none |
		tr '\000' '\377' > "$erased_nvram"
	if ! cmp -s "$psp_nvram" "$erased_nvram"; then
		echo "Heads PSP_NVRAM must be erased (all 0xff) for first transition" >&2
		exit 1
	fi

	cp "$REFERENCE" "$OUTPUT"
	dd if="$HEADS_ROM" of="$OUTPUT" bs="$block_size" \
		skip=$((migration_offset / block_size)) \
		seek=$((migration_offset / block_size)) \
		count=$(((image_size - migration_offset) / block_size)) \
		conv=notrunc status=none

	cmp -n "$migration_offset" "$REFERENCE" "$OUTPUT"
	cmp \
		<(dd if="$HEADS_ROM" bs="$block_size" skip=$((migration_offset / block_size)) status=none) \
		<(dd if="$OUTPUT" bs="$block_size" skip=$((migration_offset / block_size)) status=none)
	require_layout "$OUTPUT" "$new_layout" "Migrated Cezanne output"

	echo "Migrated Cezanne 26.07 full image at offset=$migration_offset"
	printf 'Reference SHA256: '
	sha256sum "$REFERENCE" | awk '{print $1}'
	printf 'Heads SHA256: '
	sha256sum "$HEADS_ROM" | awk '{print $1}'
	printf 'Output SHA256: '
	sha256sum "$OUTPUT" | awk '{print $1}'
	echo "Verified: EC, MRC cache, SMMSTORE, and console remain per-unit;"
	echo "PSP_NVRAM is erased and the new FMAP/COREBOOT tail is installed."
	echo "This first-transition image requires an external full-chip programmer."
	exit 0
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
