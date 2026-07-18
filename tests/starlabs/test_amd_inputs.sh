#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/Makefile" <<EOF
build := /verified-build
pwd := $repo_root
CONFIG_STARLABS_AMD_BINARIES := y
coreboot_dir := test
include $repo_root/modules/starlabs-amd-binaries

.PHONY: print-amd-dir
print-amd-dir:
	@printf '%s\n' '\$(STARLABS_AMD_BINARIES_DIR)'
EOF

amd_dir=$(make -s -f "$tmpdir/Makefile" \
	STARLABS_AMD_BINARIES_DIR=/unverified print-amd-dir)
[ "$amd_dir" = /verified-build/amd_binaries ]

echo "Star Labs AMD input tests passed"
