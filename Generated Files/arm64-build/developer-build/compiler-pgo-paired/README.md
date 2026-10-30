# Paired compiler TieredPGO policy — readiness only

This manual-only fork harness changes **only** the private SDK's
`VBCSCompiler.runtimeconfig.json` `System.Runtime.TieredPGO` to `false`.
Baseline is the original SDK bytes. Tiered compilation, QuickJit, ReadyToRun,
all analyzers/generators, docs, target frameworks, locales, and shared
compilation remain ordinary defaults. Product source is exactly
`06efc928e31486923754398007f4f78003e04ee3`; instrumentation is separately
checked out. No product proposal, SDK replacement, environment-global runtime
override, counter tool, profiler, or custom P37 candidate is included.

The registered workflow is `.github/workflows/compare-arm64-developer-build.yml`,
fork/ref guarded to `yeelam-gordon/aspire:perf/arm64-compiler-pgo`, manual only,
read-only contents, two native ARM64 host jobs, immutable action pins unchanged.
**Do not push or dispatch without the parent's explicit authorization after its
independent audit and new 20-edit long-session gate.** This source preparation
neither runs that gate nor establishes the ordinary developer-build goal.

## Prospective execution

Each host performs exactly one untimed cache warmup per policy followed by
baseline/candidate/candidate/baseline. Every arm starts with equal clean/setup
and exact private SDK process reset, excluded from command timing. Each arm has
cold, no-op, then eight fixed comment edits. Corresponding edit bytes and
timestamps are identical, and original source/config bytes and timestamps are
restored. A fixed future edit timestamp forces recompilation despite coarse
filesystem timestamp resolution; no-op is measured before those edits.
Filesystem/NuGet caches are warm: "cold" means cleaned outputs and fresh compiler.
These node lifetime controls are **not pool-local ordinary developer timings**.
The job has a 30-minute bound, no alternate pool or automatic requeue/retry.

Timed commands are ordinary `dotnet build src/Aspire.Hosting/Aspire.Hosting.csproj
--configuration Debug --no-restore --nologo /bl:<case>/build.binlog`.
Restore and clean are excluded. Only the tiny offline reader setup uses
`/p:UseSharedCompilation=false /nr:false`; product commands have neither.
Offline replay, process/native/library identity and byte comparisons occur
outside command timing. Csc counts must be 15/0/14, with actual server-processed
messages, successful tasks, no diagnostics, and unchanged compiler commands.
Csc task elapsed sums are work-wall sums, **not CPU**. The main compile retains
all 26 analyzer/generator inputs; that quality gate is not reduced for macOS.

The dynamic per-platform manifest includes all final bin files and emitted
`.cs/.resources/.xml/.json/.dll/.pdb` files from both selected projects' Debug obj
trees, without locale/framework exclusions. Only non-emitted obj cache/log/file
list/editorconfig/response files are excluded, following frozen P38 rules.
Every corresponding case is compared byte-for-byte across all arms; each
no-op is also compared to its cold outputs. There is no assumed macOS count of
119. Empty, missing, extra and changed outputs fail.

## Ownership and cleanup

A pre-bootstrap UTC epoch and fresh product `.dotnet` path establish job
ownership, including bootstrap-created MSBuild parents. Each stop revalidates
exact PID, birth and path. Only that private job SDK's processes may be stopped;
no name kill or global server shutdown is used. Owned MSBuild nodes stop before
compilers between arms. PID reuse, runtime/native disagreement and any process
whose exit cannot be established fail the gate, not a zero or liveness fallback.

The earlier P29 macOS cleanup timeout's cause remains unknown. New diagnostics
retain exact native `ps` PID/parent/state/start/path, observer PID/runtime,
sourced identity, and before/after stop evidence. Native zombie output is
diagnostic, **not success**. Runtime absence plus native `ps` absence is required.
Raw evidence is retained on failure. Config/source restoration runs even after
cleanup failure, but no further arm is started. Results are precreated before
bootstrap, with always-upload of results and product logs.

## Source validation and remaining uncertainty

Run `Test-PairedPgo.ps1 -ResultsDirectory <new-owned-path>` with PowerShell 7
for P29 identity/native-header fixtures and paired pure helper cases. These
perform no restore, product build, compiler launch, profiler or process kill.
Frozen P38 scripts are inert provenance, never dot-sourced by this harness.
P29 `Compiler-Identity.ps1` is reused directly; the small offline reader is its
SDK-reference-only portable reader with command/analyzer/diagnostic recording.

Manual-only loose inputs have no selector-gated regular-PR consumer and require
no invented `run_*` or PR test map route. The existing dispatch lane owns them;
no test-selection map/filter is changed. Source fixtures and YAML/actionlint
checks do not establish native macOS process, loaded-library, build, binlog,
cleanup, output parity or performance success. Reader compilation and actual
Windows/macOS runner behavior remain unverified until separately authorized.
