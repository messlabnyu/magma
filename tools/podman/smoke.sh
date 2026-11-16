#!/usr/bin/env bash
# Four sequential mini-runs, after building the four images. No long run starts.
set -euo pipefail
(( $# == 1 )) || { echo "Usage: $0 NEW_RESULT_ROOT" >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$(dirname "$1")"
mkdir "$1"
root=$(realpath "$1")
export TIMEOUT=${TIMEOUT:-2m}
fuzzer=${FUZZER:-afl}
for pair in 'libpng libpng_read_fuzzer' 'sqlite3 sqlite3_fuzz' \
            'openssl x509' 'libxml2 libxml2_xml_read_memory_fuzzer'; do
    read -r target program <<< "$pair"
    bash "$repo/tools/podman/run.sh" "$fuzzer" "$target" "$program" \
        "$repo/targets/$target/corpus/$program" "$root/$target"
done
