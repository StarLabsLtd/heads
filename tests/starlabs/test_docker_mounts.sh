#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# shellcheck source=../../docker/common.sh
. "$repo_root/docker/common.sh"

export HEADS_DISABLE_USB=1
export HEADS_X11_XAUTH=1
export HOME=$tmpdir
export HEADS_DOCKER_READONLY_MOUNTS="$tmpdir/source=$tmpdir/target"
opts=$(build_docker_opts)
grep -Fx -- "type=bind,src=$tmpdir/source,dst=$tmpdir/target,readonly" \
	<<<"$opts" >/dev/null

docker() {
	touch "$tmpdir/docker-ran"
}

for invalid in missing_separator '=missing_source' 'missing_target='; do
	export HEADS_DOCKER_READONLY_MOUNTS=$invalid
	if run_docker test-image true >/dev/null 2>&1; then
		echo "Docker accepted malformed read-only mount: $invalid" >&2
		exit 1
	fi
	[ ! -e "$tmpdir/docker-ran" ]
done

echo "Docker read-only mount tests passed"
