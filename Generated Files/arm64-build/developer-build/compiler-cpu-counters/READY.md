# P29 follow-up: source-only paired collector readiness

**READY for parent review, not authorized to run.** Overall primary build-performance goal remains active. P30 owns the current timed local workload. This follow-up performed **no product build, reader build, clean, SDK launch/preflight, counter sampling, idle observation, push, or workflow dispatch**.

## What changed

- Shared CPU collection remains `System.Diagnostics.Process.TotalProcessorTime`, `UserProcessorTime`, and `PrivilegedProcessorTime`, with monotonic command wall and separate observer CPU/lag. No sampled THREADTIME, profiler, startup hook, kernel/native capture, runtime-version override, or additional package.
- `Compiler-Identity.ps1` provides small, directly used identity/header helpers. Windows retains one CIM query per new private-root PID/start-time. Mac uses `Get-Process` candidates first, then **one targeted** `/bin/ps -ww -p <PID> -o 'pid=,ppid=,comm=,args='` per new private-root identity. No `ps -axo` arguments scan, periodic WMI/ps watcher, or exported command-line dump.
- The predecessor's three-field format is retained: PID, PPID, untouched `comm+args` tail. Comments and fixtures cover native compiler apphost, private `dotnet exec ...VBCSCompiler.dll`, quoted/spaced roots, and malformed/mismatched identities.
- Actual executable path, private SDK root boundary, and PID birth time guard ownership and cleanup. Compiler/header failures retain the verified ownership record for exact-PID cleanup. Other roots, sibling-prefix roots, lexical traversal, PID reuse and changed executable paths are rejected. There is no global server shutdown or name kill.
- Native executable identity comes from a bounded actual-file header read: ARM64 PE or **thin little-endian executable Mach-O64** (`MH_MAGIC_64`, `CPU_TYPE_ARM64`, `MH_EXECUTE`). x64, fat/universal, swapped, truncated and unknown formats reject preflight/CPU coverage. Universal binaries are deliberately not inferred from a slice list.
- Future preflight also requires native ARM64 OS/observer, private SDK `--info` Host architecture `arm64`, exact product commit, source-clean root, and no existing owned compiler. SDK info, hardware and native image identity are retained. The apphost's requested runtime config is retained when available; the actual SDK/compiler keeps its default runtime resolution. We do **not** force the compiler onto the SDK host's runtime.
- Paths, PATH separator, SDK executable name, hardware discovery, and the offline Csc verifier are now platform-aware. Original P29 evidence under `run-01` is not resampled or rewritten.
- New `-PreflightOnly` stops before clean/build/edit or compiler sampling. It does launch SDK `--info` when eventually executed on a runner; **it was not run locally in this follow-up**.
- Every future Csc must report actual server compilation; fallback or missing server confirmation rejects the case before proceeding. CPU permission/lifetime/read failures explicitly reject the metric, retain logs/last snapshots, and never become zero/default success.

## Background CPU, bounded workload and limits

The accepted Windows no-op's **0.828125 s CPU with zero Csc** remains a measurement limit, not request CPU. Each case retains baseline/final cumulative counters. CPU is all activity of the retained private compiler during that window, including background/lingering work; it is not main Hosting Csc CPU alone.

The prospective pair has exactly **one cold-clean Hosting command, one genuine no-op, one warm comment edit per native host**, default analyzers/generators/docs/frameworks, and no CLI, MT or separate satellite benchmark. The normal project's satellite compilations remain part of default behavior.

An optional **single 500 ms unbuilt server observation** is implemented but defaults off (`-IdleObservationMilliseconds 0`, workflow `observe_idle: false`). If the parent later opts in, it occurs after no-op and before edit and retains its own baseline/final CPU plus observer overhead. It is labelled background-server observation, not idle/GC/request CPU; **nothing is subtracted** from build metrics. It has not been executed.

Instrumented walls remain diagnostic. Interval, observer CPU, discovery lag, baseline lead, final snapshot tail and lifetime coverage remain in raw results. CPU/wall is effective cores; CPU can exceed wall. No wait-time subtraction, critical-path/component attribution, population parity, or platform performance conclusion is warranted yet.

## Source-only checks actually executed

From `Q:\aspire`, these passed without a compiler/product workload:

```powershell
$base = 'Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters'
& "$base\Test-CompilerIdentity.ps1"
```

Result: **13 fixture groups passed**, including native apphost and `dotnet exec` positives, private root/case/delimiter negatives, PID/birth/executable cleanup guards, ARM64-vs-x64 PE/Mach-O headers, bounded native-header file IO, and malformed/universal header rejection. No fixture launches a process or reads process CPU. The synthetic header file is created only inside `source-checks` and removed.

PowerShell parser checks passed for all four scripts and every workflow inline PowerShell block. Existing `powershell-yaml` parsed the candidate workflow. The manual-only trigger and unchanged action pins were checked against corrected primary source `2816396d304e91c5c347d69e47bb7d54cb5828fd`, successful run **40883755604**. No tools/packages were installed. Evidence: `source-checks\identity-fixtures.json`, `parse-checks.json`, `workflow-review.json`.

No product/reader build, MTP suite or selector suite was run: this is source-only preparation while P30 times its workload, not a CI or runtime pass.

## Minimal manual integration prepared, not activated

Local candidate `compare-arm64-developer-build.yml` targets the **existing registered manual path** `.github/workflows/compare-arm64-developer-build.yml`, on owned branch `perf/arm64-compiler-cpu-counters`.

- Reuses primary runner labels `windows-11-vs2026-arm` and `macos-latest`, native architecture guard, corrected absolute-project-path bootstrap, and exact existing checkout/upload pins.
- Read-only contents permission; fork + exact branch guard; **workflow_dispatch only**; no PR/push/schedule trigger or `run_*` gate.
- Separate checkouts: instrumentation at event SHA, **unchanged product pinned to `06efc928e31486923754398007f4f78003e04ee3`**. Both identities and runner image are recorded. No product/version/global.json/package/API edit.
- Bootstrap, fixtures, SDK-only preflight and tiny offline reader build occur outside build timers. Only that reader build disables shared compilation/node reuse so it leaves no server before the cold product command; the measured product commands have no such flags.
- Always-upload retains raw command arguments, binlogs, stdout/stderr, CPU snapshots, identities/native headers, SDK/hardware/environment, failure/coverage, source restoration and cleanup data.

Routing audit: `.github/instructions/test-trigger-map.instructions.md` and the map's Maintenance section were read. These loose helper inputs have one **dedicated dispatch-only consumer**, not a selector-gated regular-PR test/job. The standalone reader is not a solution test project. No map, upstream filter or selector change is required, and no PR-runnable target is invented. No copied production functions or exact-command Infrastructure.Tests were added; fixtures invoke the actual identity helpers.

Action pins are unchanged first-party `actions/*` references, so no new allow-list SHA is introduced. YAML parsing is not a GitHub execution/permission pass.

## Prospective commands — review only, NOT executed

On each future native runner, after the existing project-scoped restore:

```powershell
# $product is the isolated unchanged-06ef checkout.
# $helper is instrumentation's assigned compiler-cpu-counters directory.
# $evidence is an initially absent owned evidence subtree.
& (Join-Path $helper 'Test-CompilerIdentity.ps1') -ResultsDirectory (Join-Path $evidence 'source-checks')
& (Join-Path $helper 'Measure-CompilerCpu.ps1') -RepositoryRoot $product -ResultsDirectory (Join-Path $evidence 'preflight') -PreflightOnly
# The candidate workflow builds the tiny reader outside measurement here.
& (Join-Path $helper 'Measure-CompilerCpu.ps1') -RepositoryRoot $product -ResultsDirectory (Join-Path $evidence 'measurements') -IdleObservationMilliseconds 0
& (Join-Path $helper 'Verify-Counters.ps1') -ResultsDirectory (Join-Path $evidence 'measurements')
```

Inside the collector the only measured command is the unchanged default:

```text
<private native dotnet> build src/Aspire.Hosting/Aspire.Hosting.csproj --configuration Debug --no-restore --nologo /bl:<owned case binlog>
```

The three cases differ only by clean/setup or the restored comment edit, outside the timer. Local Windows commands use native Windows separators; the Mac source constructs native path separators.

Only if the parent later reviews, approves publication, and separately authorizes execution would this existing manual path be eligible:

```powershell
gh workflow run compare-arm64-developer-build.yml --repo yeelam-gordon/aspire --ref perf/arm64-compiler-cpu-counters -f observe_idle=false
```

That is a prospective invocation, **not a dispatch instruction or a selected next CI experiment**. No push or dispatch occurred.

## Confidence and remaining runner-only unknowns

**High confidence in source fixture/safety checks; medium confidence in prospective cross-platform readiness; no Mac runtime pass claimed.**

Actual Mac `Process.Path`, process start-time stability/permissions, `ps` output, CPU APIs, memory/thread fields, SDK/compiler file headers, runtime resolution, hardware commands, final-alive coverage, counter consistency and observer overhead all remain unverified on a Mac runner. Fat/universal or unusual native headers intentionally fail rather than guess. The ported Windows collector is also not rerun during P30.

The next authority is the parent review of READY and local branch source, not this document. The overall primary goal remains open.
