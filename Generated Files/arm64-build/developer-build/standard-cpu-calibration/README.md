# P48 isolated standard CPU calibration preparation

This branch is **local preparation only**. No push or dispatch is authorized.
The eventual named question is mature common Csc CPU ownership, not a cold
Windows penalty. This fixture does not build/profile Aspire or reopen P21.

The existing registered manual workflow
`.github\workflows\compare-arm64-developer-build.yml` (ID 400645444) is reused
only on `perf/arm64-standard-cpu-calibration`. There is one Windows ARM64 job,
at most 15 minutes, no Mac, PR, push or schedule trigger. Both job and script
require the exact owned fork/ref/manual event and hosted ARM64 image.
The capture entry point has **no local override**. The first isolated recording
would be a new known-work calibration, not a retry of a local recording.

## What is prepared

- `KnownWork.cs`: readiness identity handshake; two 2-second named `Burn`
  phases alternating with two 2-second `Sleep` phases; process CPU, UTC and
  monotonic anchors. Work starts only after `go`; graceful `end` plus watchdogs.
- `Build-Tools.ps1`: direct pinned Csc with existing reference assemblies,
  no MSBuild/compiler server/restore or SDK writes locally. Copies existing
  TraceEvent 3.1.28 and its ARM64 native asset into private decoder output.
- `Invoke-Control.ps1`: **unprofiled only**, no collector option or callback.
- `Setup-Hosted.ps1`: guarded SDK-only ARM64 subset of the existing P44
  repository bootstrap, avoiding the product restore/x64-runtime loop.
- `Invoke-HostedCalibration.ps1`: standard installed CPUUsageLow at 100 Hz,
  exact owned live PID/birth/path, one GUID session, bounded start/stop/expand,
  no collision retry, no stopping a session without successful start receipt,
  no service/protection/global-interval adjustments. Normal broker access may
  start the service; its observed state is retained and never stopped by us.
- `CpuDecoder.cs`: public `ZippedETLReader` and `TraceLog` APIs, real kernel
  `SampledProfileTraceData` plus `CallStack()` mappings, exact owned process and
  phase windows. Aggregate counts cover all matching samples; stack examples
  are bounded. No thread-time/residence synthesis or private API disassembly.

The dedicated ephemeral runner addresses shared-host data acquisition risk.
It does **not** prove the agent physically samples only the selected PID.
Standard archive shape, ETL count, runtime coverage, known-method symbols,
loss and privileges remain runner-only discriminators. Unknown/degraded output
is retained and rejected, not retried. The prepared runner currently leaves
final collector loss **unknown** unless independently established: even a
zero decoder count cannot manufacture a complete-attribution claim.

## Public headless precedent and its limit

Pinned source:
[TraceEvent 3.1.28 ZippedETL.cs](https://github.com/microsoft/perfview/blob/5fc5e080bc57237df3371def6946275b7c6552a9/src/TraceEvent/ZippedETL.cs).
It explicitly handles `.diagsession` GUID `symcache`/`pdbcache` paths and rejects
zero/multiple ETLs. Archive plumbing fixtures exercise those actual APIs.
That is a real headless path to test, **not** proof of this CPUAgent version's
as-yet-unrecorded archive. The first recording must surface incompatibility.

## Local commands (no recording)

Use the already provisioned native private SDK and pinned package; supply fresh
output directories under MAIN `standard-cpu-readiness\isolated-readiness`.

```powershell
& .\Build-Tools.ps1 -Sdk $sdk -TraceEventPackage $package -Output $binaries
& .\Invoke-Control.ps1 -Sdk $sdk -Binaries $binaries -Output $control
& .\Test-Preparation.ps1 -Sdk $sdk -Binaries $binaries -Output $tests
```

`Test-Preparation.ps1` exercises pure positive/negative hosted guards, actual
local capture-entry rejection before side effects, and public archive APIs.
It never simulates an allowed hosted environment to execute a recording.

## Test-selection ownership

These standalone inputs are consumed only by this dedicated manual branch
workflow, not `Aspire.slnx` or any regular-PR test/job. The exact subtree is
classified in the trigger map's `ignore` section with that rationale; this
does not add a `tests.yml` job/`run_*` gate. The workflow itself retains the
general `Infrastructure.Tests` route. Focused real-map tests verify the manual
input, workflow routing and adjacent unknown-path fallback. No broad
`Generated Files/**` exclusion or top-level CI skip rule is added.

Acceptance/evidence and parent-owned remaining decisions live in MAIN
`standard-cpu-readiness\isolated-readiness\REPORT.md`/`REPORT.json`, not in a
product performance claim.
