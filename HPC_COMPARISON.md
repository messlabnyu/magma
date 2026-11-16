# LAVA / deeper LAVA / MAGMA: initial assessment

**Current execution plan:** use the RHEL server with [the Podman scripts and run guide](tools/podman/README.md) first. The HPC/SIF scripts remain an alternative. Podman scripts passed shell syntax and mock-runtime checks; the event exporter passed synthetic trigger/censoring and early-failure checks. No actual Podman image build or campaign has run here.

**Survival claim:** rerunning MAGMA on the same server and common time/resource budgets gives a cleaner external reference than importing historical results. A defensible conclusion is “LAVA 2.0's observed survival distribution is closer to this MAGMA baseline under our evaluated setup.” A matching median does not demonstrate real-bug equivalence, and MAGMA's age is not the whole limitation: driver exposure, instrumentation, bug mix and trigger/crash definitions can affect survival independently. Use censoring-aware estimates; if survival never reaches 50%, the median is not reached. Keep target/fuzzer strata visible and include uncertainty. The existing `tools/benchd/survival_analysis.py` computes restricted mean survival time, not median survival.

## Clarified plan: keep the frameworks separate

Run MAGMA as the real-bug baseline; run original/deeper LAVA in FuzzBench. There is no need to import MAGMA's bugs into FuzzBench. Pin FuzzBench's clean upstream sources to MAGMA's revisions, then inject the respective LAVA bugs. Keep drivers, build settings, fuzzer implementations, and evaluation budgets comparable. Separate reports still need one common per-bug outcome definition; their default report scores are not automatically comparable.

**Two kinds of seeds:** the inputs used to *inject* LAVA bugs are your experimental treatment: original inputs for LAVA 1.0, concolic-generated inputs for LAVA 2.0. These should differ by design. The inputs supplied when *evaluating* the resulting buggy programs should be the same frozen corpus for MAGMA, LAVA 1.0, and LAVA 2.0. You can reuse MAGMA's existing corpus if it works with the common driver and passes common validation; changing it is not inherently required. Keep injection inputs and known triggering witnesses out of the evaluation corpus. If evaluation seeds also change, the result measures placement plus seeding, rather than placement alone.

**One MAGMA evaluation is fine; one random trial is weak evidence.** Run repeated independent campaigns within that evaluation and save them all. A practical small pilot is five repeats per fuzzer/target/variant, followed by more repeats if the results are noisy. Match repeats, wall time, allocated CPUs and memory across all three variants, including MAGMA. Report the injection-generation compute separately. For four targets × four fuzzers (AFL, AFL++, libFuzzer, SymCC+AFL) × five repeats, there are 80 campaigns per variant. At one CPU for each ordinary fuzzer and two for each hybrid, all concurrent campaigns would reserve 100 CPU slots, before overhead; first check whether the server's 128 CPUs are physical cores or SMT threads. Longer scientific runs can use the same schedule after the one-hour smoke test.

**Podman on RHEL 9 is a plausible simpler route than HPC.** Podman builds Dockerfiles and runs OCI images ([Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_starting-with-containers_building-running-and-managing-containers)). `FROM ubuntu:18.04` specifies container userspace; it does not require an Ubuntu host. The container shares the RHEL kernel, so fuzzers still need a smoke test. Old package repositories and dependencies may complicate rebuilding; host/container distribution names alone are not the blocker.

For Captain, use Podman's Docker-compatible command (`podman-docker`) or adapt its Docker invocations; a shell alias is insufficient for the child scripts. Set `CACHE_ON_DISK=1` to bypass the sudo tmpfs mount. On SELinux-enabled RHEL, add `:Z` to each dedicated campaign results bind mount; check rootless UID ownership (often `--userns=keep-id` for these images), CPU binding and tracing permissions. Use `docker.io/library/ubuntu:18.04` to avoid ambiguous short-name lookup. These are compatibility changes to validate, not a claim that current Captain already works with Podman. The added `tools/hpc/run.sh` is specifically for SIF execution, not Podman.

Do not start the final MAGMA evaluation until the target/driver/corpus/fuzzer/budget choices are frozen; otherwise the saved baseline may need rerunning.

Inspected 16 November 2026: MAGMA `75d1ae7b180443a778b8830c79176ca5f93642ac`; FuzzBench `3234e151d70f6093272a9b4155e68ee57faf986c` (use `git -C ~/fuzzbench rev-parse HEAD` to verify). Findings describe source recipes, not successfully built binaries. Neither repository was changed to align versions yet.

## 1. Can MAGMA run on NYU HPC?

**Yes, with an Apptainer/Singularity launcher; the current Captain launcher cannot run unchanged.** It calls Docker, builds during scheduling, uses Docker CPU binding, and mounts tmpfs with sudo by default. See [run.sh](tools/captain/run.sh), [start.sh](tools/captain/start.sh), [build.sh](tools/captain/build.sh). Setting `CACHE_ON_DISK=1` removes the sudo mount, but does not remove Docker.

Build images on your Docker-capable server, convert them to SIF, and run those under Slurm. Keep the Dockerfile: it remains the build recipe. Each campaign needs its own writable results and seed directories, isolated processes/IPC, and only its allocated CPUs. MAGMA's canary storage is a regular mapped file at `/magma_shared/canaries.raw`, not a requirement for a privileged host tmpfs mount ([prebuild.sh](magma/prebuild.sh), [canary.c](magma/src/canary.c)).

Added [run.sh](tools/hpc/run.sh), [inside.sh](tools/hpc/inside.sh), [smoke.sbatch](tools/hpc/smoke.sbatch), and [local-smoke.sh](tools/hpc/local-smoke.sh). They bypass Captain, keep the supplied starting corpus, record image/seed hashes and runtime arguments, and save monitor data and rotating logs. This is an initial launcher, not a validated HPC port. Site restrictions on IPC namespaces, tracing/perf, and available memory still require a compute-node smoke test; Docker's `SYS_PTRACE`/seccomp settings cannot simply be transferred to an unprivileged HPC job.

NYU currently documents Apptainer on Torch and requires container workloads on compute nodes: [NYU guide](https://services.rt.nyu.edu/docs/hpc/tutorial_apptainer/running_containers/). Your actual cluster/account may have different module and partition names; the Slurm example deliberately leaves those to submission options.

## 2. Target revisions and seeds

Commit IDs are the authoritative versions here; do not replace them with guessed release numbers.

| Target | MAGMA: `targets/<target>/fetch.sh` | FuzzBench: `benchmarks/<benchmark>/` |
|---|---|---|
| SQLite | `8c432642572c8c4b` | `sqlite3_ossfuzz`: archive `c78cbf2e86850cc6`; YAML commit empty |
| OpenSSL | `3bd5319b5d0df9ecf05c8baba2c401ad8e3ba130` | `openssl_x509`: YAML `b0593c086dd303af31dc1e30233149978dd613c4` |
| libpng | `a37d4836519517bdce6cb9d956092321eca3e73b` | `libpng_libpng_read_fuzzer`: YAML `cd0ea2a7f53b603d3d9b5b891c779c430047b39a` |
| libxml2 | `ec6e3efb06d7b15cf5a2328fabd3845acea4c815` | `libxml2_xml`: YAML `c7260a47f19e01f4f663b6a56fbdc2dafd8a6e7e` |

FuzzBench also has `libxml2_xml_e85b9b`, a separate bug benchmark pinned to `E85F9B98A5389C69167176AE6600091E719EC38F`. Select benchmark names explicitly.

**OpenSSL trap:** its Dockerfile clones tag `openssl-3.0.7`, but FuzzBench subsequently checks out the YAML commit. See [builder Dockerfile](../fuzzbench/docker/benchmark-builder/Dockerfile) and [checkout script](../fuzzbench/docker/benchmark-builder/checkout_commit.py). A successful normal build therefore uses the YAML revision. **SQLite trap:** the builder passes the empty commit unquoted, so the checkout script receives too few arguments and can fail; quote `"$CHECKOUT_COMMIT"` when repairing that recipe, or give the checkout step a deliberate SQLite-aware bypass. Merely filling YAML with the archive ID will not create a Git checkout in the extracted archive.

**Prefer aligning FuzzBench to MAGMA**, in new benchmark entries, leaving the originals intact. MAGMA's `patches/setup` and `patches/bugs` are tied to its revisions ([apply_patches.sh](magma/apply_patches.sh)). Updating MAGMA's `fetch.sh` means porting those patches and verifying each bug still exists and is reachable. This is substantially more work than changing a revision.

For FuzzBench copies: set the three Git targets' YAML commits to MAGMA's IDs; change SQLite's Dockerfile archive URL and handle its empty checkout correctly. Reuse MAGMA's drivers and compatible build options too. libxml2's FuzzBench `fuzz/xml.c` driver differs from MAGMA's `targets/libxml2/src/libxml2_xml_read_memory_fuzzer.cc`; revision alignment alone does not fix that. SQLite also differs in `--enable-rtree`. Compare all four `build.sh` recipes. libpng copies upstream `build.sh` **before** the later checkout, so copy/use the intended build recipe after pinning. Pin dependencies (including zlib), compiler, optimization, sanitizers, and dictionaries.

MAGMA seeds live in `targets/<target>/corpus/<program>/`. FuzzBench normally uses `<fuzz_target>_seed_corpus.zip`: SQLite's source `.test` files, OpenSSL's `fuzz/corpora`, and libxml2's generated `fuzz/seed/xml` ([runner.py](../fuzzbench/experiment/runner.py), target Dockerfiles/build scripts). libpng also carries `benchmarks/libpng_libpng_read_fuzzer/seeds`; inspect the resulting archive, not just that directory. **These are not established as identical seed sets.**

Freeze one corpus per shared driver, with hashes; feed identical bytes to every variant/fuzzer. In FuzzBench, supply that corpus through its custom corpus mechanism (`--custom-seed-corpus-dir`, with a subdirectory per benchmark; see `experiment/run_experiment.py` and `experiment/runner.py`) or an explicitly replaced output seed ZIP. Verify the actual post-preparation corpus: FuzzBench filters oversized inputs and normalizes filenames. MAGMA's original `magma/run.sh` deletes fault-triggering seeds per build and has a suspicious empty-corpus check against `$1`; the new HPC launcher bypasses this script. Prevalidate one common starting corpus across **all** variants, excluding known triggers consistently; do not prune separately per variant.

## 3. Running it

Use the commands in [the run guide](tools/hpc/README.md): build with Docker on the server, convert to SIF, test one campaign locally, then submit the same launcher through Slurm. Start with four concurrent repeats before using all 128 cores. Request at least two CPUs initially for SymCC+AFL/Eclipser; plain AFL and libFuzzer examples use one. The one-hour test is for operation, not comparative hardness.

## 4. Fuzzers: overlap and recommendation

Exact shared directory names include AFL, AFLFast, AFL++, FairFuzz, Honggfuzz, libFuzzer, Eclipser, KLEE and `symcc_afl`; MAGMA `moptafl` corresponds to FuzzBench `mopt` in intent, not necessarily implementation. Directory presence does not establish working target support.

| Engine | MAGMA recipe | FuzzBench recipe |
|---|---|---|
| AFL | `61037103ae3722c8060ff7082994836a794f978e` | tag `v2.57b` |
| AFL++ | `458eb0813a6f7d63eed97f18696bca8274533123` | intended `56d5aa3101945e81519a3fac8783d0d8fad82779`; checkout failure is swallowed by `|| true` |
| libFuzzer | LLVM `29cc50e17a6800ca75cd23ed85ae1ddf3e3dcc14` | LLVM `5cda4dc7b4d28fcd11307d4234c513ff779a1c6f` |
| Honggfuzz | `fc6b818c1276056bc565d07edec6ada784cd1670` | moving branch `oss-fuzz`; comment is not a pin |
| SymCC+AFL | upstream SymCC `82151a62e3b702a2c699ca4d8ef91d3bf9beeb2b`, AFL `610371…` | AdaLogics **adacc fork** `edda79dcb830c95ba6d303e47c698839313ef506`, AFL `82b5e359463238d790cadbe2dd494d6a4928bff3`; QSYM dependency uses moving branch |
| Eclipser | moving shallow HEAD, also unpinned AFL | Eclipser `ba1d7a55c168f7c19ecceb788a81ea07c2625e45`; AFL `82b5e359…` |

Verify in MAGMA `fuzzers/<name>/fetch.sh` and FuzzBench `fuzzers/<name>/{builder,runner}.Dockerfile`. Matching names currently do **not** imply matched engines, forks, instrumentation or runtime settings. Pin full revisions and dependencies; remove checkout fallbacks; record actual built revisions. Align driver patches, compiler and settings, not just version labels.

**Recommended main set: AFL++, libFuzzer, and SymCC+AFL, plus plain AFL as the matched baseline for SymCC.** Eclipser is an optional second concolic approach. KLEE is symbolic execution but is not a substitute for a working concolic hybrid. SymCC+AFL is explicitly present in MAGMA; FuzzBench `symcc_afl` runs two AFL workers plus the helper, while MAGMA runs one AFL plus the helper. FuzzBench `symcc_afl_single` is structurally closer, but still uses a different fork. SQLite explicitly excludes both and `symcc_aflplusplus` in its `benchmark.yaml`: solving SQLite support is a prerequisite, not something to assume. Prove a helper-generated input reaches the AFL queue on every target before including that hybrid in results.

## 5. Experiment concerns

- **Separate placement from seeds.** Test ordinary/deeper LAVA × ordinary/generated starting corpora; use identical corpora across bug variants within each seed condition. Also test generated seeds with fuzzers that do not use concolic execution. Training/injection seeds and evaluation seeds should be separated; report any overlap and seed-generation compute cost.
- **Keep other causes fixed.** Use a common clean source revision and driver for three separately built variants: original-LAVA injection, deeper-LAVA injection, and MAGMA bugs. Do not accidentally leave MAGMA bugs active in LAVA variants. `CANARY_MODE=3` enables MAGMA fixes, but disables its canaries and is not a drop-in LAVA measurement solution; explicitly define each patch set and bug oracle.
- **Measure depth rather than infer it.** Report distance from the driver, required branch conditions, seed coverage, and reach/trigger times. A hard magic-value check, a missing driver path, or a broken injection can look like a deep bug. Validate triggers with held-out witnesses and confirm the bugs are reachable.
- **Use comparable outcomes.** Unique crashes are not unique bugs. Use per-bug reach/trigger detection and reproducible triggering inputs; separately report sanitizer crashes. MAGMA's canaries and LAVA's predicates need a consistent definition of success. Equalize CPU-hours, memory, sanitizers and instrumentation overhead; hybrids consume multiple workers.
- **Limit the conclusion.** Control bug count, placement distribution and injection randomness; use multiple independent injections and repeated fuzzing runs with uncertainty intervals. Report fraction of known bugs triggered and time-to-trigger, including unfound bugs. Four targets and one hour cannot establish general equivalence to real bugs; lower discovery alone does not establish realism. Test at longer fixed budgets after the smoke run.

Validation: shell syntax passed; a mock runtime verified arguments, private seed copying, hash records, refusal to reuse output directories, and parallel repeats. Container execution remains untested. No target compilation, LAVA injection, one-hour campaign, or NYU job has been run.
