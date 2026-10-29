# One bounded hosted managed-graph comparison

Question: does the completed local wide-graph MT benefit survive the actual
Windows Cobalt 100 and Mac M1 hosted ARM64 runners, and how do their gaps/ratios
change? This is a new throughput question, not another native trace capture.
P21 run 40897380288 had a rejected Windows capture and a Mac job with zero
steps; it is not a throughput baseline. The native collector time-box is closed.

Product source: `06efc928e31486923754398007f4f78003e04ee3`.
Only this directory and the existing manual workflow path are added. No default
branch change, upstream write, PR, profiler, retry or alternate runner is allowed.
One two-job dispatch; cancel if a platform never acquires capacity and retain
the blocker. Each running job has a 30-minute timeout. Queue observation is
bounded to approximately 20 minutes from dispatch, not an automatic redispatch.

## Protocol and quality boundary

The standard native repository SDK bootstrap and restore run first. Preseed
the repository-required 10.0 runtime in separate native/x64 roots using the
bootstrap's standard installer to avoid Arcade's known mixed-architecture
installer defect (`dotnet/arcade#16584`). This is setup correctness, not a
speedup. SDK, native runtime and hardware evidence are retained.

Each platform runs **normal, MT, MT, normal**, serially. Each arm uses the
standard `build.cmd` / `build.sh` `-clean`, then `-restore` outside timing and
`-build` inside timing, Debug, with:

```text
/p:SkipNativeBuild=true /p:SkipBundleDeps=true
/p:SkipTestProjects=true /p:SkipPlaygroundProjects=true /nr:false
```

MT additionally uses `/mt /m`. Normal analyzers, generators, templates,
localization and OuterPreBuild validation remain. Evaluated scope must contain
148 selected csproj and OuterPreBuild. Both modes use fresh MSBuild nodes to
isolate `dotnet/msbuild#15213` (fixed upstream in #15214, absent from this SDK).
This is not a production-default workaround recommendation.

Setup, all build logs/binlogs and exact `Aspire*.dll` inventories/bytes,
including retained satellites, are uploaded independently of success.
Compare bytes **within** a platform only; no normalization. Non-prefix
assemblies, other generated artifacts and runtime behavior are not verified.
Standard template localization can remove two stale placeholder choice keys
in 14 tracked files; the pristine pre-arm state and generated patch are
retained, only those exact paths are restored, and unexpected changes fail.

This is neither compiler-only nor shipping/native/publish/pack/test parity,
nor ordinary single-project edit latency. Two samples/mode on one machine per
platform do not establish population statistics. Compiler task duration sums
overlap; they are not CPU time or critical-path attribution. No adoption
recommendation follows from these timings.

## Local checks and consumers

PowerShell parser, actionlint (only its stale Windows-label warning allowed),
XML parsing of the existing Versions.props, real SDK/PE/evaluated-graph
`-ValidateOnly` smoke and exact-byte analyzer positive/negative fixture checks
precede dispatch. Parent already ran the full four-arm Windows protocol;
do not repeat that batch as a smoke test.

The sole consumer is this manual fork workflow. No regular-PR job, selected
test target, artifact consumer, reusable workflow, AzDO pipeline or test
project changes; no test-selection map update is required. Existing checkout
and upload action pins are unchanged from prior fork experiments.
