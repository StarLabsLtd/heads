#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

build_dir="$tmpdir/build"
amd_dir="$build_dir/amd_binaries"
test_root="$tmpdir/repo"
manifest="$test_root/config/starlabs-amd-binaries.sha256"
mkdir -p "$amd_dir" "$test_root/config"
printf 'first input\n' > "$amd_dir/input.bin"
(cd "$amd_dir" && sha256sum input.bin) > "$manifest"

cat >"$tmpdir/Makefile" <<EOF
build := $build_dir
pwd := $test_root
CONFIG_STARLABS_AMD_BINARIES := y
coreboot_dir := test
include $repo_root/modules/starlabs-amd-binaries

.PHONY: print-amd-dir
print-amd-dir:
	@printf '%s\n' '\$(STARLABS_AMD_BINARIES_DIR)'

\$(build)/\$(coreboot_dir)/.configured:
	@mkdir -p '\$(dir \$@)'
	@printf 'configured\n' >> '$tmpdir/configured.log'
	@touch '\$@'

\$(build)/\$(coreboot_dir)/.build: \$(build)/\$(coreboot_dir)/.configured
	@printf 'built\n' >> '$tmpdir/build.log'
	@touch '\$@'
EOF

reported_amd_dir=$(make -s -f "$tmpdir/Makefile" \
	STARLABS_AMD_BINARIES_DIR=/unverified print-amd-dir)
[ "$reported_amd_dir" = "$amd_dir" ]

target="$build_dir/test/.build"
make -s -f "$tmpdir/Makefile" "$target"
make -s -f "$tmpdir/Makefile" "$target"
[ "$(wc -l < "$tmpdir/configured.log")" -eq 1 ]
[ "$(wc -l < "$tmpdir/build.log")" -eq 1 ]

sleep 1
printf 'second input\n' > "$amd_dir/input.bin"
(cd "$amd_dir" && sha256sum input.bin) > "$manifest"
make -s -f "$tmpdir/Makefile" "$target"
[ "$(wc -l < "$tmpdir/configured.log")" -eq 2 ]
[ "$(wc -l < "$tmpdir/build.log")" -eq 2 ]

echo "Star Labs AMD input tests passed"
