# Ordinary Hosting: owned compiler CPU counters

P29's executed Windows proof is historical evidence, **not closure of the primary build-performance goal**. The subsequent Mac/paired preparation is source-only; see `READY.md`. No product/reader build or timed observation was run for that follow-up.

## Result and confidence

**Medium confidence overall; high confidence in this Windows process-counter coverage.** Three bounded local commands completed successfully on 2026-10-30 (UTC+08). The actual native ARM64 SDK compiler server was identified, retained through every final measurement, and stopped afterwards. Counters establish real cumulative process CPU, not sampled thread residence. They do **not** isolate the main Hosting compilation, individual compiler components, critical path, waiting, or Windows/Mac parity.

| Case | Command wall s | Compiler CPU s | User s | Kernel s | CPU/wall (effective cores) | Csc count | Main Hosting Csc wall s | All Csc wall sum s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Cold compiler + project clean | 25.0730649 | 119.750000 | 116.078125 | 3.671875 | 4.77604 | 15 | 14.7878548 | 16.8488111 |
| Genuine no-op | 0.8317967 | 0.828125 | 0.781250 | 0.046875 | 0.99559 | 0 | 0 | 0 |
| Warm comment edit | 10.2886191 | 75.562500 | 74.609375 | 0.953125 | 7.34428 | 14 | 9.4291507 | 9.5766201 |

CPU can exceed wall because it sums all compiler threads. CPU/wall is effective cores, **not machine CPU percent**. No CPU-minus-wall “wait” calculation is valid or made. Csc task elapsed sums are not CPU and are not critical-path durations.

Cold means compiler-process cold and project `clean`, **not** OS/file-cache cold. This is one sample per case, not a throughput or cache-warmup conclusion. The previous cross-platform pair is not reused as a CPU baseline.

The cold command contains one analyzer-project `CoreCompile`, one main Hosting `CoreCompile`, and 13 Hosting satellite `Csc` invocations. The edit has one main Hosting `CoreCompile` plus the 13 satellites. Offline binlog replay confirmed **every one** of these Csc tasks emitted `CompilerServer: server - server processed compilation`. There was no Csc task in the no-op. `csc.json` retains task project, target, timestamps, elapsed, success, and actual compiler-server diagnostics.

**Important attribution limit:** no-op still accrued 0.828125 s of compiler-server CPU with zero Csc tasks. These counters measure all activity of the retained server during the measurement window, including possible lingering/background work from earlier compilations; they cannot assign that CPU to the no-op request. Similarly, cold/edit totals include all compiler-server work in their command windows, not just main Hosting task CPU. No GC, analyzer, generator, startup, scheduler, or CPU-component cause is established.

## Identity, machine, and coverage

- Exclusive source-clean root: `Q:\aspire-perf-scheduler-diagnostic`.
- Product commit: `06efc928e31486923754398007f4f78003e04ee3`.
- Windows `10.0.26200`, Microsoft Virtual Machine, Cobalt 100, **16 cores / 16 logical processors**, 68,708,864,000 physical-memory bytes; observer is native ARM64 PowerShell 7.6.9.
- Existing restored native SDK: `11.0.100-rc.2.26504.105`, MSBuild `18.12.0-1.26504.105`. No SDK setup or tool installation was needed.
- Actual server **PID 32064**, start `2026-10-29T23:37:29.7015495Z`; private executable `Q:\aspire-perf-scheduler-diagnostic\.dotnet\sdk\11.0.100-rc.2.26504.105\Roslyn\bincore\VBCSCompiler.exe`.
- Apphost PE machine **0xAA64** independently checked (`compiler-native-identity.json`).
- Command-line identity was confirmed once through CIM, including its private SDK path and compiler pipe. Parent **24908** was the same-root native MSBuild `/nodemode:8` helper.
- Observer PID **31988**. Build launcher PIDs **26416**, **31124**, **30248** are labels only: their CPU is **not** presented as the whole build engine or compiler.
- Discovery supports private-root native `VBCSCompiler.exe` and private `dotnet exec ...VBCSCompiler.dll`. PID + process start time guards prevent reuse mistakes. No global process shutdown or name-based termination is used.
- Cold server was absent before clean/build, created after command start, and discovered **0.2685955 s** after creation. Its cold CPU baseline is **zero at process creation**, so startup CPU before first discovery is included.
- Warm lifetimes were properly differenced: no-op **120.015625 → 120.843750 s**; edit **121.015625 → 196.578125 s**. Neither warm metric is lifetime CPU.
- Compiler snapshots per case: **111 / 5 / 49**, all alive, all three counters monotonic, and total = user + kernel exactly in every retained snapshot. Counters exhibit 15.625 ms granularity here.
- Final snapshots follow observed launcher exit by approximately **5.395 / 5.608 / 3.729 ms**. Warm baseline windows lead launch by at most **9.098 / 8.841 ms**. They are close boundary approximations, not perfectly atomic command boundaries.
- Final process CPU remains live-process CPU, not exit CPU. Background CPU after the final snapshot is not counted; process death before final coverage is an explicit metric failure, never zero.
- The executed P29 version was Windows-only. Current source now includes macOS discovery/ownership and thin Mach-O ARM64 header checks, validated only with Windows-hosted source fixtures. Actual Mac APIs, native files, compiler CPU and final coverage remain **runner-only/unvalidated**; this is not a fabricated Mac pass.

API semantics: [Process.TotalProcessorTime](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.totalprocessortime?view=net-10.0) is the sum of user and privileged process CPU. Wall is `Stopwatch` monotonic elapsed. This is not P20 sampled THREADTIME and uses no WPR, kernel trace, profiler installation, or event buffers.

## Memory and overhead

| Case | Final working set bytes | Max sampled working set bytes | Max sampled threads | Observer CPU s | Poll body wall s | Max observed poll gap s |
|---|---:|---:|---:|---:|---:|---:|
| Cold | 833921024 | 833921024 | 62 | 2.906250 | 1.3449996 | 0.3179161 |
| No-op | 836861952 | 836861952 | 61 | 0.390625 | 0.1182706 | 0.2847385 |
| Edit | 991481856 | 991526912 | 62 | 0.515625 | 0.5489600 | 0.2834952 |

Requested wait interval is **200 ms**, plus discovery/snapshot work, not a guaranteed 200 ms period. CIM verification happens once per new private-root PID/start-time, never on every poll. Raw snapshots also retain kernel-maintained lifetime peak working set and private bytes.

This is bounded, event-free, modest absolute overhead, **not zero overhead**: poll body wall is about 5.36% / 14.22% / 5.34% of command wall. Observer CPU is about 0.116 / 0.470 / 0.050 effective cores. The short no-op has material relative observation overhead; do not treat these walls as uncontaminated throughput measurements. Observer CPU is separate from compiler CPU and includes baseline/final observation. JIT/initialization and new-process identity verification are not subtracted. There is no unobserved control experiment here.

## Executable helper and exact validation

Files:

- `Measure-CompilerCpu.ps1`: ordinary product commands, owned discovery/counters, concurrent stdout/stderr draining using `ProcessStartInfo.ArgumentList`, source edit/byte restoration, exact-PID cleanup, overwrite/source/platform guards.
- `binlog-reader`: tiny standalone, SDK-assembly-only offline replay utility, no NuGet package dependencies.
- `Verify-Counters.ps1`: replay/counter acceptance checks and `run-01\verified-summary.json`.
- `run-01`: exact arguments, binlogs, stdout/stderr, identities, snapshots, machine/environment, cleanup, and source restoration evidence. `measurements.json`/`result.json` are original capture records; `verified-summary.json` supplies normalized zero Csc sums.

Reader setup command, run from the already-restored worktree (passed, zero warnings/errors; `reader-build.log`):

```powershell
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' build 'Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters\binlog-reader\Reader.csproj' --configuration Debug --nologo /p:UseSharedCompilation=false /nr:false
```

Those two flags apply **only to the standalone analysis helper**, outside all measured product commands. They are not product-build quality/mode changes.

Actual diagnostic execution (passed, three product commands, `execution.log`):

```powershell
& 'Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters\Measure-CompilerCpu.ps1'
```

Project clean/setup was outside counters/build timer (passed, `clean-command.json` and `clean.*.log`):

```powershell
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' clean src\Aspire.Hosting\Aspire.Hosting.csproj --configuration Debug --nologo
```

Exact measured commands, all exit 0:

```powershell
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' build src\Aspire.Hosting\Aspire.Hosting.csproj --configuration Debug --no-restore --nologo '/bl:Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters\run-01\cold-clean\build.binlog'
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' build src\Aspire.Hosting\Aspire.Hosting.csproj --configuration Debug --no-restore --nologo '/bl:Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters\run-01\no-op\build.binlog'
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' build src\Aspire.Hosting\Aspire.Hosting.csproj --configuration Debug --no-restore --nologo '/bl:Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters\run-01\warm-comment-edit\build.binlog'
```

Scheduler/path/server/MT environment overrides were explicitly unset; initially no MSBuild/DOTNET/COMPlus overrides were present. Only private `DOTNET_ROOT`, PATH selection, and console terminal-logger disabling were set. No `/mt`, parallelism override, shared-compilation disablement, analyzer/generator/docs/framework changes, AOT, publish, or pack in product measurements.

After measurement the replay utility was extended to retain Csc target/server messages, rebuilt outside measurement (passed, zero warnings/errors, `reader-rebuild.log`), and the **existing three binlogs** replayed; no further product build ran:

```powershell
$base = 'Q:\aspire\Generated Files\arm64-build\developer-build\compiler-cpu-counters'
& 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' build "$base\binlog-reader\Reader.csproj" --configuration Debug --no-restore --nologo /p:UseSharedCompilation=false /nr:false
foreach ($case in @('cold-clean', 'no-op', 'warm-comment-edit'))
{
    & 'Q:\aspire-perf-scheduler-diagnostic\.dotnet\dotnet.exe' "$base\binlog-reader\bin\Debug\net11.0\Reader.dll" "$base\run-01\$case\build.binlog" "$base\run-01\$case\csc.json"
}
& "$base\Verify-Counters.ps1"
```

All three replays and offline verification **passed**. After capture, the measurement helper received reporting-only normalization (console CPU output, empty Csc sum), failure-path log/launcher retention and timeout hardening; final PowerShell parse passed. Successful measurement/counter logic was not rerun or resampled. Original execution's blank console CPU display was a dictionary/`Measure-Object` presentation issue; retained JSON contained the correct CPU values, independently reconstructed by verification.

The only temporary product source change appended one comment to `src\Aspire.Hosting\DistributedApplication.cs`. Original bytes and timestamp were restored in `finally`; `final-state.json` confirms byte equality and completely clean `git status --porcelain`. Only identified compiler PID **32064** and owned MSBuild helper **24908** were terminated, with exit confirmation, after evidence retention. Final audit confirms no remaining process from this private SDK root.

**P29 execution stop boundary:** local Windows discriminator proved and artifacts retained. At that boundary no CI, packaging, new system/native capture, platform port, additional pair, or next experiment was selected. The separately requested source-only follow-up does not close the overall primary goal or authorize a run.
