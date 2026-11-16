# MAGMA on RHEL 9 with Podman

This folder bypasses Captain and uses the existing MAGMA Dockerfile and target/fuzzer recipes. No HPC, Apptainer, Docker daemon, or source-version migration is required. Start with AFL/libpng. These scripts have not yet been executed against real Podman or built target images.

Local validation completed: shell syntax; mock Podman build/run commands, CPU/mount arguments, seed copying, metadata, duplicate-output rejection and failure propagation; synthetic trigger/censoring exports and early-exit rejection. These checks do not establish that a target builds or a fuzzer operates correctly on RHEL.

Host requirements: rootless Podman with configured subordinate UID/GID ranges, Bash, Git, coreutils, findutils, awk, util-linux (`lscpu`, `taskset`), network access for builds, and sufficient disk. Python 3 is needed only for the optional event exporter. Run as your normal user. No host package installation or system configuration is performed by these scripts.

## First mini-run after SSH

From your checked-out MAGMA repository:

```bash
podman info
lscpu
bash tools/podman/build.sh afl libpng

# Inspect allowed CPU IDs. They need not start at zero.
python3 -c 'import os; print(sorted(os.sched_getaffinity(0)))'

# CPUS defaults to the first allowed logical CPU; set it explicitly if desired.
TIMEOUT=2m MEMORY=4g bash tools/podman/run.sh \
  afl libpng libpng_read_fuzzer \
  targets/libpng/corpus/libpng_read_fuzzer podman-results/png-mini-01

cat podman-results/png-mini-01/container-exit-code
cat podman-results/png-mini-01/fuzzer-exit-code
tail -n 30 podman-results/png-mini-01/container.log
tail -n 30 podman-results/png-mini-01/log/current
find podman-results/png-mini-01/monitor -type f
```

Expected: container exit `0`, fuzzer exit `124` (time budget exhausted), monitor snapshots, and AFL statistics showing executions. Finding zero bugs in two minutes is normal. Check `findings/fuzzer_stats` (or fuzzer-specific subdirectories) for actual progress; a sleeping or stalled fuzzer can also exhaust its budget. Do not accept the timeout alone as proof of a working experiment. An early fuzzer exit is treated as a failed campaign.

Results directories must be new. Every campaign copies its seeds privately, records their initial SHA-256 hashes, the immutable image ID/configuration, host CPU information, launch arguments, container state and exit codes. The image is run by ID to avoid a tag changing underneath the campaign. Results/seed bind mounts receive private SELinux labels (`:Z`); original repository seeds are not relabeled or modified. The image uses UID/GID 1000 internally; `--userns=keep-id:uid=1000,gid=1000` maps the invoking host account to those IDs. This avoids trying to reproduce potentially very large university account IDs inside a rootless build. Rebuild older images with the updated script before running.

If a build reports `chown ... Invalid argument`, check `id`, `podman unshare cat /proc/self/uid_map`, and `podman unshare cat /proc/self/gid_map`. Container UID/GID 1000 must be mapped; if subordinate ranges are missing or too small, the host administrator must configure them. The fixed-ID change handles high host IDs but cannot repair an absent subordinate-ID allocation. The build now explicitly supplies empty `isan`, `harden` and `fixes` arguments to suppress warnings while preserving nonfatal canaries and enabled bugs.

Build records go to `podman-build-logs/`. The Dockerfile itself now uses `docker.io/library/ubuntu:18.04`, installs `util-linux`, and gives optional canary arguments empty defaults. The build script uses that file directly and saves an unchanged copy with its records. Nonfatal canaries and default instrumentation flags remain in use. Ubuntu userspace inside a RHEL container host is normal; it does not install Ubuntu on the host. Old repositories/packages or fuzzer dependencies may still fail to build. Stop at the first failure and retain its log; do not change versions silently to get a build through.

## Mini-runs for all four targets

```bash
for target in libpng sqlite3 openssl libxml2; do
  bash tools/podman/build.sh afl "$target" || break
done
FUZZER=afl TIMEOUT=2m bash tools/podman/smoke.sh podman-results/four-mini-01
```

The mini-runs are sequential: approximately eight minutes plus startup. The common drivers selected are libpng's read fuzzer, SQLite's `sqlite3_fuzz`, OpenSSL's `x509`, and libxml2's memory-read fuzzer. They do not expose every bug in every target. Images must all build successfully before the smoke script can complete.

For another fuzzer, build that fuzzer/target image first. SymCC+AFL and Eclipser require at least two allowed CPU IDs, e.g. `CPUS=4,5`. Confirm helper-generated inputs are actually exchanged with AFL. Default AFL++ uses an extra comparison-instrumented binary and may need more memory. Identical engine names across FuzzBench and MAGMA do not establish identical implementations.

## Longer runs, only after inspecting mini-runs

```bash
# Example: five sequential 24-hour trials, one chosen allowed CPU.
# Choose and validate the shared evaluation corpus before this stage.
for repeat in 0 1 2 3 4; do
  CPUS=4 TIMEOUT=24h MEMORY=4g bash tools/podman/run.sh \
    afl libpng libpng_read_fuzzer /absolute/path/frozen-png-corpus \
    "podman-results/png-final-$repeat" || break
done
```

Use separate CPU sets and result paths for simultaneous campaigns. Do not give all parallel runs the same `CPUS`. Confirm physical cores versus SMT threads and leave capacity for monitoring/storage. Match duration, repeats, CPU allocation and memory limits across MAGMA/LAVA variants. This folder intentionally does not add a cluster scheduler or automatic resume. Use a persistent SSH session manager for long runs.

The launcher pins its in-container shell with `taskset`; child processes inherit that affinity, recorded in `cpu-affinity.txt`. It deliberately avoids Podman's `--cpuset-cpus`, because the RHEL account tested here lacks delegation of that cgroup controller. This is process affinity rather than an exclusive CPU reservation; allocate distinct CPU sets to parallel campaigns and check fuzzer-specific affinity behavior. Updated builds explicitly install `util-linux` for `taskset`; an existing image can be reused if it already contains that command.

The launcher also requests memory/swap limits, private IPC, no network, and upstream-style tracing capability/seccomp settings. On rootless RHEL, inspect `podman info`, warnings and saved container state to verify the host actually enforces memory limits; cgroup delegation differs by host. Do not fix ownership problems with recursive `chown` of your repository or disable SELinux globally.

The launcher sets `AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1`, as this FuzzBench checkout's `fuzzers/afl/fuzzer.py` does, to bypass AFL's abort on a piped host `core_pattern`. It records the pattern and override in each campaign. This permits startup but does not remove crash-reporting delays; validate crash-versus-timeout classification before collecting final results. No host sysctl is changed.

## Reading results and survival times

### Comparison settings to freeze before final runs

The inspected FuzzBench local runner template has no `--memory` container limit; its `runner_memory: 12GB` default is a cloud provisioning setting, not a local 4 GiB cap. Explicitly configure and verify a common container limit. MAGMA's plain AFL recipe separately uses `-m 100M`; FuzzBench's AFL uses `-m none`, `-t 1000+`, `-d`, dictionaries when supplied, and a persistent-loop argument. The successful MAGMA mini-run selected a 20 ms timeout automatically and did not skip deterministic mutations. These are meaningful differences, not CPU-only differences. Inspect `fuzzbench/experiment/resources/runner-startup-script-template.sh`, `experiment/run_experiment.py`, and `fuzzers/afl/fuzzer.py` in the adjacent checkout.

Freeze CPU slots/worker counts, container and per-target memory limits, per-input timeout, engine revision/options, duration/repeats, evaluation corpus/dictionaries, and trigger definition. Keep source/driver/compiler/sanitizer differences explicit. Defaults are acceptable for operational pilots; choose final comparison settings before collecting the final MAGMA baseline. FuzzBench's current local launcher also expects privileged Docker and attempts host sysctl writes; successful rootless Podman execution of MAGMA does not establish FuzzBench compatibility.

`monitor/<seconds>` contains MAGMA's CSV counters, with `_R` for reached and `_T` for triggered. Numeric filenames use elapsed seconds since campaign startup; polling reports the first observation, not an exact trigger timestamp. Preserve `log/`, `findings/`, image/build records and original corpora. `candidate-bugs.txt` lists patch names only: it is not a validated denominator for this driver. In the current code, canary entries appear dynamically, so a bug absent from monitor output must not simply disappear from the analysis.

After defining a driver-specific bug cohort independently of which bugs were found, export one target/program's completed trials:

```bash
python3 tools/podman/export_events.py --bugs /path/validated-png-bugs.txt \
  --output png-times.csv podman-results/png-final-0 podman-results/png-final-1
```

`triggered=1` means the canary trigger was observed; `triggered=0` means right-censored at the observed campaign end. Failed/early-ending campaigns are rejected. Triggered is not necessarily a sanitizer crash or a retained, replay-validated witness. If LAVA reports crashes, either replay both into comparable per-bug trigger oracles or make that measurement difference explicit.

For analysis, predeclare whether the median is across bug×trial observations, per-bug trial distributions, or another unit; keep target/fuzzer strata visible and account for shared campaign/injection dependence. Estimate survival with censoring. If survival never falls to 50%, report the median as **not reached**. A fixed-horizon restricted mean survival time (RMST) and fraction triggered are useful secondary summaries. MAGMA's existing `tools/benchd/survival_analysis.py` computes RMST, despite its general survival-analysis name; it is not a median calculator. Use the same horizon and cohort rule for all three variants. Do not compute a median only over discovered bugs.

Rerunning MAGMA on the same machine removes historical hardware/runtime differences. It does not remove differences in drivers, instrumentation, bug distributions, or observability. The defensible claim is that LAVA 2.0's observed survival distribution is closer to this MAGMA baseline under the evaluated setup, not that matching a median proves real-bug equivalence.

## Reviewer reproduction budget

A reviewer can test one image and short campaign on a much smaller VM; the full 128-CPU server is unnecessary for checking functionality. Builds of some engines need substantially more resources than a single fuzzing worker. To check statistical results, provide prebuilt image archives/checksums, raw events, frozen corpora and the analysis script, alongside a small runnable subset.

As a public price reference checked 16 November 2026, Google's pricing table lists `n2-highmem-128` (128 vCPUs, 864 GiB) at **$7.706976/hour** for an on-demand configuration: roughly **$185/day** or **$555/72 hours**, before disks, OS licensing, taxes and other services. Region and machine availability affect the price. This is larger in RAM than your server and cloud vCPUs need not match your physical cores or throughput. [Google pricing](https://cloud.google.com/products/compute/pricing/general-purpose?hl=en)

For scale: 4 targets × 4 fuzzers × 5 repeats × 24 hours = 1,920 campaign-hours per variant. If one fuzzer uses two workers and the other three use one, that is 2,400 allocated CPU-hours per variant. At 100 usable CPU slots, the idealized runtime is 24 hours per variant, excluding builds, imbalance and overhead. Three variants are about 72 hours under those assumptions. This is a planning calculation, not a promise of cloud/server performance.

See [HPC_COMPARISON.md](../../HPC_COMPARISON.md) for the source revision inventory and known comparison differences.
