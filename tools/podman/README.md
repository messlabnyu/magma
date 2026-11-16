# MAGMA with Podman

AFL/libpng completed a two-minute run on the RHEL 9.8 server: 1.71 million executions, container exit `0`, fuzzer exit `124`. Other targets and fuzzers still need validation. Commands below run from the repository root in **Bash** (`bash` after SSH if needed).

## Build and run

Build each image before starting timed campaigns:

```bash
for target in libpng sqlite3 openssl libxml2; do
  bash tools/podman/build.sh afl "$target" || break
done
```

Start with a two-minute test; use `TIMEOUT=1h` for the hour pilot or `24h` after choosing final settings:

```bash
CPUS=0 MEMORY=4g TIMEOUT=2m bash tools/podman/run.sh \
  afl libpng libpng_read_fuzzer \
  targets/libpng/corpus/libpng_read_fuzzer podman-results/png-mini-01
```

Every run needs a **new result directory**. To test all four images sequentially:

```bash
FUZZER=afl TIMEOUT=2m bash tools/podman/smoke.sh podman-results/four-mini-01
```

| Target | Program |
|---|---|
| libpng | `libpng_read_fuzzer` |
| sqlite3 | `sqlite3_fuzz` |
| openssl | `x509` |
| libxml2 | `libxml2_xml_read_memory_fuzzer` |

Seeds are at `targets/TARGET/corpus/PROGRAM`. Parallel runs use separate result paths and CPU sets. On this server, CPUs **0–63** represent different physical cores; **64–127** are their SMT siblings. For four campaigns use CPUs 0, 1, 2, 3 and avoid scheduling your other campaigns on 64–67. SymCC+AFL/Eclipser need at least two CPUs initially, e.g. `CPUS=4,5`.

## Check results

```bash
cat podman-results/png-mini-01/container.log
cat podman-results/png-mini-01/fuzzer-exit-code
cat podman-results/png-mini-01/findings/fuzzer_stats
```

Expected: container exit `0`, fuzzer exit `124` (budget exhausted), growing execution counts and numeric snapshots in `monitor/`. On failure, also read `log/current`. A timeout alone does not prove progress.

Results retain private seed copies, initial seed hashes, image/configuration records, CPU affinity and logs. Build records are in `podman-build-logs/`. No automatic resume is provided; use a persistent terminal session for long runs.

## Before final comparisons

- Match CPUs/worker counts, duration, repetitions, evaluation seeds and dictionaries; record fuzzer, driver and build differences.
- Verify memory limits. MAGMA requests 4 GiB per container, but plain AFL also limits the target to **100 MB**. FuzzBench's local runner has no default container memory cap; its AFL uses `-m none`, `-t 1000+` and `-d`. The MAGMA pilot selected **20 ms** automatically and retained deterministic mutations.
- The launcher uses process affinity instead of the unavailable rootless `cpuset` controller. It does not reserve cores exclusively. It bypasses AFL's piped-core-handler check, matching FuzzBench; validate crash detection before final runs.
- MAGMA `_R`/`_T` counters mean reached/triggered, not necessarily sanitizer crashes. Use a predeclared driver-specific bug cohort, including unfound bugs. `candidate-bugs.txt` lists patches, not a validated cohort. Report a survival median as **not reached** if the curve never falls to 50%.

Export completed trials for one target/program after defining that cohort:

```bash
python3 tools/podman/export_events.py --bugs validated-png-bugs.txt \
  --output png-times.csv podman-results/png-hour-01
```

The exporter retains unfound bugs as censored observations and rejects failed trials. If the final monitor buffer was already consumed, the launcher retains the last sample and records `observation-end-seconds`; unfound bugs are censored there, not at a later unobserved time. A gap larger than one polling interval plus two seconds is rejected. FuzzBench's Docker launcher still needs separate Podman validation. Source versions and comparison limitations are documented in [HPC_COMPARISON.md](../../HPC_COMPARISON.md).

# FIX
```bash
python -m pip install 'setuptools==75.8.0'
python -c 'import pkg_resources; import google.cloud.logging; print("Imports OK")'

mkdir -p "$HOME/.local/bin"
tmpdir=$(mktemp -d)

curl -fL https://download.docker.com/linux/static/stable/x86_64/docker-20.10.24.tgz \
  -o "$tmpdir/docker.tgz"

tar -xzf "$tmpdir/docker.tgz" -C "$tmpdir"
install -m 755 "$tmpdir/docker/docker" "$HOME/.local/bin/docker"

export PATH="$HOME/.local/bin:$PATH"
```
