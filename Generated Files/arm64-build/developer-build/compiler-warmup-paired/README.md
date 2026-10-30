# P44 default compiler calibration

This manual-only fork lane is **not an optimization**. Product source remains
`06efc928e31486923754398007f4f78003e04ee3`, with its original native SDK/runtime
and normal quality/policy. P38/P43 candidates are not used.

Each native Windows/macOS job runs two fresh default compiler lifetimes on the
same host: cold, no-op, twenty identical-by-index comment edits (44 builds).
Early **1–5** and late **16–20** are preregistered; report each lifetime
separately. Two lifetimes are not a population or evidence of equal hardware.
The existing 30-minute bound covers bootstrap, 44 ordinary builds and the small
diagnostic; no extra unmeasured compiler-training builds are present.

## Evidence and boundaries

- Every build retains command UTC/monotonic boundaries, wall, binlog, main Csc
  wall, all Csc tasks, command lines, analyzer paths, server processing,
  actual retained server PID/birth/path, hardware and loaded runtime identity.
- Cold/no-op/edit require 15/0/14 Csc tasks, no diagnostics and 26 main analyzers.
  Complete dynamic emitted manifests and exact corresponding file bytes include
  locales, all frameworks and embedded PDBs. Source bytes **and timestamps**
  match by index and are restored in `finally`.
- Process CPU uses only begin/end getters outside command timers, not polling.
  Cold's conceptual zero is actual process creation; warm endpoints require the
  same live identity, monotonic components and consistency within 50 ms.
  Unsupported/default-zero APIs reject the metric, never substitute zero.
  CPU includes **all retained server/background activity**, not main-Csc CPU,
  machine percent, or inferred waiting. Boundary leads/tails and inter-build
  delays are retained; offline replay/output checks allow background work
  between commands and can affect warm-up.
- Only **after** throughput, a fresh diagnostic lifetime runs cold/two edits
  with normal policy and runtime EventPipe loader/JIT/NGen/compilation events.
  Provider `0x3000000038:5`, streaming, env DWORD `100` hex = 256 MiB.
  No training, forced R2R/tiering, sampling, profiler or counter tool is used.
  Diagnostic walls never become throughput samples.
- Raw nettraces plus offline JSONL retain PID, actual ThreadID, CLR instance,
  absolute/relative timestamps, module/method/ReJIT/tier payloads and loader/PDB
  paths; module files/assembly references are inventoried for later elapsed-JIT
  analysis. Verbose records, zero loss, exact compiler PID/CLR instance and
  positive R2R, instrumented and optimized tier entries are required.
  Missing serialized startup settings event 280 is **not** a failure.
- The decoder reuses P41's **TraceEvent 3.1.28 offline library**, not a new
  profiler or target dependency. Local smoke uses the existing P41 binary.
  Fresh hosted setup retrieves that same library from the already-approved
  dotnet-public feed; no package manifest/NuGet config or action pin changes.
- Exact owned-pipe native compiler shutdown **request** precedes known owned
  parent reset, which precedes required compiler/native/runtime absence.
  Non-child Unix `WaitForExit` must not block parent reaping. A proved zombie
  with unavailable runtime birth/path remains present; typed state avoids null
  method calls without granting kill/exit authority. Reaping can target only
  independently registered private SDK MSBuild nodes, never a numeric PPID alone.
  Birth/path/epoch/native-query/reuse failures and every cleanup phase are
  retained; failed requests/stops are not retried indefinitely.
  PID/birth/path/epoch guards and native absence reject zombies, reuse and
  unknown states. P29's unresolved Mac cause is not presumed fixed.
  Runtimeconfig/compiler/native image bytes and timestamps are never written.
- Hidden `.NETCoreApp`/`.NETStandard` generated sources are selected/copied/
  compared with `-Force` only inside controlled bin/obj trees and their captures.
  Upload explicitly includes hidden files **only** below
  `compiler-warmup-results/` and `product/artifacts/log/`; guards reject checkout,
  home, `.git`, traversal and broad/glob upload roots.

## Local checks

```powershell
& .\Test-PairedWarmup.ps1 -ResultsDirectory <new-evidence-directory>
python .\Test-WorkflowSource.py
& .\Invoke-LocalSmoke.ps1 -ResultsDirectory <new-evidence-directory>
```

The explicit local smoke runs **two × cold/no-op/one edit**, then a separate
cold/two-edit diagnostic. The hosted source guard always requires twenty edits;
local smoke cannot impersonate a hosted invocation. Helper/setup builds alone
use `UseSharedCompilation=false` and `/nr:false`; product builds do not.

`ContinueLocalSmokeFrom` is limited to the exact recorded first Windows smoke
failure after its first three successful builds (quoted whole pipe argument).
It validates frozen ownership/source/quality evidence and runs **only** the
unfinished second lifetime and diagnostic into a new directory. It cannot
resume hosted work or overwrite the failed attempt. See the coordinator's
`compiler-warmup-paired\readiness` report for all executed attempts and repairs.

## Selection and dispatch

The only consumers of these loose inputs are this dedicated `workflow_dispatch`
lane and its local fixtures. There is no PR/push/schedule trigger or eligible
regular-PR test consumer; no invented test-trigger-map route is added.
Existing first-party action pins are unchanged. Artifacts upload `always()`;
timing, CPU, diagnostics and restoration gates remain separate.

Manual `platform` is a constrained choice: **both** (default), **windows**, or
**macos**. A fixed mapping selects only the existing native labels; invalid
values have no mapping, not a broader fallback. Every selected host still runs
both default twenty-edit lifetimes and its separate three-build diagnostic.
No new action pin, product scope or automatic trigger is introduced.

Windows smoke is harness validation, **not** a performance result. Actual Mac
API/trace/cleanup coverage, full twenty-edit trajectories and hosted acquisition
remain unvalidated until a separate fresh parent-owned gate. No push or
dispatch is authorized by source readiness.

Run `41003828322` remains rejected: Mac completed one twenty-edit lifetime, then
retained a defunct compiler under its owned MSBuild parent; finally cleanup hit
the unavailable-StartTime null-method path. Windows archives lost two declared
dot-generated files, while Mac enumeration omitted them. These repairs do not
reconstruct old missing bytes or prove historical P29's cause. Captured-state
ordering/null/reuse fixtures and real Windows Hidden-attribute copy/compare/ZIP
fixtures are local checks, **not native Mac or GitHub artifact-upload passes**.

Run `41009645939` verified complete 119-file uploads, but remains failed:
the immediate post-ACK `?<E` sample was fed into the authority/absence
classifier and aborted before independently proved parent reset. Finally
observed `Z<` and established absence; that does not make the run pass.
Post-ACK samples are now explicitly **observation-only**: unavailable fields
are logged unresolved, never child-kill or exit authority. Concrete native
query/reuse/path/parent contradictions still fail. Parent action independently
revalidates registry/private path/epoch/PID/birth, and only the unchanged final
bounded native+runtime absence phase can confirm exit. No transient ps-state
whitelist was added. Native Mac repaired-source proof remains unexecuted.

The timed harness, CPU endpoint implementation, build/quality/output scope,
twenty-edit workload, CLR provider/buffers and readers are unchanged from
`86276b9890`. A focused Mac-only validation may therefore be considered by the
coordinator using prior accepted Windows evidence, but source invariance is
not identical hardware/run context or permission to dispatch.
