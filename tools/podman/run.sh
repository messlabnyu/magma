#!/usr/bin/env bash
# Rootless Podman campaign, pinned CPUs, fresh results, no Captain dependency.
set -euo pipefail
if (( $# != 5 )); then
    echo "Usage: $0 FUZZER TARGET PROGRAM SEEDS NEW_RESULT_DIRECTORY" >&2
    exit 2
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fuzzer=$1 target=$2 program=$3
for name in "$fuzzer" "$target" "$program"; do
    [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
done
seeds=$(realpath "$4") result=$(realpath -m "$5")
[[ -d $seeds && -n $(find "$seeds" -maxdepth 1 -type f -print -quit) ]] || {
    echo 'Supply a nonempty seed directory' >&2; exit 2;
}
allowed=$(awk '$1 == "Cpus_allowed_list:" {print $2}' /proc/self/status)
cpus=${CPUS:-${allowed%%[-,]*}}
# Let taskset validate the CPU list and ask the kernel which CPUs are usable.
cpus=$(taskset -c "$cpus" awk '$1 == "Cpus_allowed_list:" {print $2}' /proc/self/status)
cpu_count=$(awk -F, '{for (i=1; i<=NF; i++) {n=split($i,r,"-"); total += n==2 ? r[2]-r[1]+1 : 1} print total}' <<< "$cpus")
if [[ $fuzzer == symcc_afl || $fuzzer == eclipser ]] && (( cpu_count < 2 )); then
    echo 'Select at least two available CPUs for this hybrid using CPUS.' >&2
    exit 2
fi
image="localhost/magma/$fuzzer/$target:baseline"
image_id=$(podman image inspect --format '{{.Id}}' "$image")
[[ $(podman image inspect --format '{{index .Labels "org.magma.fuzzer"}}' "$image_id") == "$fuzzer" ]]
[[ $(podman image inspect --format '{{index .Labels "org.magma.target"}}' "$image_id") == "$target" ]]
container_uid=$(podman image inspect --format '{{index .Labels "org.magma.uid"}}' "$image_id")
container_gid=$(podman image inspect --format '{{index .Labels "org.magma.gid"}}' "$image_id")
[[ $container_uid == 1000 && $container_gid == 1000 ]] || {
    echo 'Rebuild this image with the updated tools/podman/build.sh (fixed container IDs).' >&2
    exit 2
}
mkdir -p "$(dirname "$result")"
mkdir "$result" # Never mix trials or resume silently.
mkdir "$result/seeds"
cp -RL "$seeds/." "$result/seeds/"
chmod -R u+rwX "$result/seeds"
cp "$repo/tools/podman/inside.sh" "$result/inside.sh"
podman image inspect "$image_id" > "$result/image.json"
podman info > "$result/podman-info.txt"
lscpu > "$result/lscpu.txt"
git -C "$repo" rev-parse HEAD > "$result/launcher-revision.txt"
cp "$repo/tools/podman/run.sh" "$result/launcher.sh"
(
    cd "$result/seeds"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
) > "$result/seeds.sha256"
# Candidate inventory only: not proof that every patched bug is exposed by this
# driver. Define a validated analysis cohort before computing survival curves.
find "$repo/targets/$target/patches/bugs" -name '*.patch' -printf '%f\n' | \
    sed 's/\.patch$//' | sort > "$result/candidate-bugs.txt"
{
    printf 'fuzzer=%s\ntarget=%s\nprogram=%s\ncpus=%s\nmemory=%s\ntimeout=%s\npoll=%s\nargs=%s\nfuzzargs=%s\ncpu_binding=process-affinity\n' \
        "$fuzzer" "$target" "$program" "$cpus" "${MEMORY:-4g}" \
        "${TIMEOUT:-5m}" "${POLL:-5}" "${ARGS:-}" "${FUZZARGS:-}"
    date -u +%FT%TZ
} > "$result/campaign.txt"
name="magma-$(id -u)-$$-$(date +%s)"
cleanup() { podman rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set +e
podman run --name "$name" --userns=keep-id:uid=1000,gid=1000 --user 1000:1000 \
    --network=none --ipc=private --memory "${MEMORY:-4g}" \
    --memory-swap "${MEMORY:-4g}" --shm-size=256m \
    --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    --volume "$result:/magma_shared:Z" \
    --volume "$result/seeds:/magma/targets/$target/corpus/$program:Z" \
    --entrypoint /bin/bash "$image_id" /magma_shared/inside.sh \
    "$fuzzer" "$target" "$program" "${TIMEOUT:-5m}" "${POLL:-5}" \
    "${ARGS:-}" "${FUZZARGS:-}" "$cpus" > "$result/container.log" 2>&1
status=$?
set -e
podman inspect "$name" > "$result/container.json" 2>/dev/null || true
printf '%s\n' "$status" > "$result/container-exit-code"
echo "Container exit $status; results: $result"
exit "$status"
