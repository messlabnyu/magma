#!/usr/bin/env bash
# Build one existing MAGMA recipe, without changing Captain or target sources.
set -euo pipefail
(( $# == 2 )) || { echo "Usage: $0 FUZZER TARGET" >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fuzzer=$1 target=$2
for name in "$fuzzer" "$target"; do
    [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
done
[[ -d $repo/fuzzers/$fuzzer && -d $repo/targets/$target ]] || exit 2
command -v podman >/dev/null
tag="localhost/magma/$fuzzer/$target:baseline"
logdir=${BUILD_LOG_DIR:-$repo/podman-build-logs}
mkdir -p "$logdir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$logdir/${fuzzer}-${target}-${stamp}"
git -C "$repo" status --short > "$log.git-status"
git -C "$repo" rev-parse HEAD > "$log.git-revision"
# Save the exact build recipe with the build records.
cp "$repo/docker/Dockerfile" "$log.Dockerfile"
podman build --format docker -t "$tag" \
    --label "org.magma.fuzzer=$fuzzer" --label "org.magma.target=$target" \
    --label "org.magma.uid=1000" --label "org.magma.gid=1000" \
    --label "org.magma.revision=$(git -C "$repo" rev-parse HEAD)" \
    --build-arg "fuzzer_name=$fuzzer" --build-arg "target_name=$target" \
    --build-arg USER_ID=1000 --build-arg GROUP_ID=1000 \
    --build-arg canaries=1 --build-arg isan= --build-arg harden= --build-arg fixes= \
    -f "$repo/docker/Dockerfile" "$repo" 2>&1 | tee "$log.log"
podman image inspect "$tag" > "$log.image.json"
echo "Built $tag; build records: $log.*"
