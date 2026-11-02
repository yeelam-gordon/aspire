# HOBL Aspire workload-recipe adapter

This is a **required companion scenario**, not a substitute for normal CI or local
developer-build evidence. It reproduces the pinned HOBL Aspire **workload recipes**,
not HOBL's privileged lab orchestration, measurement plugins, RPC, or machine tuning.
See `manifest.json` for immutable HOBL, Aspire v9.4.2, and installer provenance.
It never builds the current checkout or the P22 subset/patched engine.

## Local execution

Use native ARM64 PowerShell >7 on native ARM64 Windows or macOS. Git, Node and npm
must already be available. macOS also requires existing Xcode command-line tools
and x64 translation support for this source's grpc.tools protoc; original Mac prep
requires Python **3.12.10** on `python3`. Nothing installs Rosetta, changes a shell
profile, invokes winget/brew/pyenv, or edits machine security/settings.

```powershell
pwsh -NoProfile -File .\eng\perf\hobl\validate.ps1
python .\eng\perf\hobl\validate-workflows.py
pwsh -NoProfile -File .\eng\perf\hobl\run.ps1 -Platform macos -Profile original -Plan
pwsh -NoProfile -File .\eng\perf\hobl\run.ps1 -Profile original -Loops 4 -BudgetMinutes 30 -BudgetGiB 20
pwsh -NoProfile -File .\eng\perf\hobl\run.ps1 -Profile aligned -Loops 4 -BudgetMinutes 30 -BudgetGiB 20
```

`-Plan` supports either OS without installation. `-Loops 1` is smoke only, **not**
a complete HOBL result. The entire attempt, including setup, is bounded; there is
no automatic timing retry. Storage is checked during child execution (every 30s)
and at command completion: the budget is an abort threshold, not a filesystem
quota. Timeouts kill only the adapter's own child tree. All evidence is retained.
Twenty seconds **inside the original total budget** are reserved for orderly
`dotnet build-server shutdown` using this run's actual private SDK. Workload
commands expire before that interval; shutdown is attempted even after workload
time/storage exhaustion. Cleanup failure makes the result failed, not silently
passed. The reservation does not extend the requested total budget.
The adapter never deletes a workload workspace.
The optional parsed workflow validator requires existing PyYAML. `validate.ps1`
needs no Python/package installation and checks both plans, confinement, missing
evidence, workflow isolation and an independent owned server surviving workload
expiry until reserved cleanup shuts it down. Use actionlint
too when available; neither static validator establishes Actions admission.
After a private setup attempt, `validate-nuget-boundary.ps1 -SdkDirectory
<sdk-root>\sdk\10.0.100-preview.5.25277.114 -SourceConfig
<run>\source\NuGet.config` exercises the **actual pinned NuGet engine** against a
local ghost-feed fixture, checking actual retained audit/disabled-source/fallback/
trusted-author/require-signature settings without network or changing either source config.
`validate-routing.ps1 -SourceRoot <run>\source` executes the pinned Bash
`InitializeDotNetCli` function against owned SDK-directory fixtures: `tools.runtimes`
must select `source\.dotnet`, ignoring a valid decoy `DOTNET_INSTALL_DIR`, and fail
without installation when the correct SDK is absent. Windows uses Git's Bash.

Every attempt creates a fresh randomly named owned directory under this checkout's
`artifacts\hobl` (override only to another strict descendant). It downloads the
pinned official installer, installs ARM64 SDK 8.0.427 then exact SDK 10 preview 5,
and .NET/ASP.NET runtimes 8.0.18/9.0.6 in native and `<sdk-root>\x64` locations.
The solution profiles install at `<run>\dotnet`; **original Mac installs at
`<run>\source\.dotnet`**, because pinned `eng\common\tools.sh` ignores the supplied
`DOTNET_INSTALL_DIR` when `global.json` contains `tools.runtimes`. A preflight
executes that pinned routing function without allowing SDK installation and checks
that the wrapper selects the same verified root used for shutdown. No junction,
symlink, global.json edit or bootstrap override substitutes another SDK.
Private package, cache, CLI and scratch roots are passed only to children.
Explicit SDK first-use switches prevent persistent user PATH additions and HTTPS
development-certificate generation; `DOTNET_SKIP_FIRST_TIME_EXPERIENCE` alone is
not sufficient on modern SDKs. Windows also checks for an owned tools-path leak
before accepting the final result.
Inherited MSBuild output/import-path overrides are cleared in children so a
developer shell cannot redirect a clean into another checkout.
Owned-source Git operations use command-scoped `core.longpaths=true` for long snapshot names;
it does not modify global Git configuration or Windows registry settings.
SDK-bundled runtimes also remain installed and are recorded; do not assume runtime
roll-forward selected 8.0.18 merely because that required runtime is present.
The source is nested inside this checkout, unlike upstream's drive-root clone.
A **new owned workspace** `NuGet.Config` clears **only packageSourceMapping**
before the unchanged v9.4.2 config supplies its mappings. Otherwise ancestor exact
mappings can point to feeds removed by that source's own `packageSources/clear`,
producing NU1100. No feed is added. Audit sources, disabled sources, fallback
folders, trusted signers and signature-validation settings remain inherited.
This intentionally replaces inherited **mapping** policy; it is not a claim that
all inherited routing policy is preserved. Neither checked-in nor user config is
edited. Mac `HOME` is retained so user policy is not hidden; explicit private
CLI/package/cache/scratch roots isolate writes. If retained policy blocks restore,
report that blocker rather than relaxing it. The boundary is retained as evidence.
There is no machine/shared SDK root or SDK 11/12 fallback. No restore is run against the
adapter checkout; the private pinned source is the workload.
For setup-repair validation only, optional `-SetupSeedFrom <previous-owned-run>`
copies this adapter's own verified pinned SDK/package/download cache into the new
owned run. All installers, host/SDK/provenance checks and schema prep still run,
the source clone is fresh, and no timed evidence is reused. Seed provenance is
recorded and links are rejected. CI does not seed setup. The default uses fresh
private installs; this is never a route to a P22/patched or machine SDK.
Seeding, copying and upstream prebuild all influence compiler/filesystem caches.
Label such results **original workload recipe; seeded private setup; upstream
prebuild; uncontrolled cache state**, not a cold or normalized HOBL lab baseline.
NuGet skips source-mapping lookup for packages already in its global packages
folder; validate changed mapping policy with fresh owned package storage rather
than treating seeded restores as proof of allowed download routing.

## Recipe and timing semantics

| Profile | Windows | macOS |
|---|---|---|
| `original` | `dotnet clean Aspire.slnx`; `dotnet restore Aspire.slnx`; timed `dotnet build Aspire.slnx --no-restore` | `./build.sh --clean`; `./build.sh --restore`; timed `./build.sh --build` |
| `aligned` | Same Windows solution recipe | Same Windows solution recipe and prep |

Original raw Windows/Mac differences are **not OS-only**: project selection,
validation and restore/build behavior can differ. The aligned companion removes
that recipe mismatch, not hardware/toolchain/environment differences.
Schema regeneration is untimed upstream prep on **both** original platforms:
Windows uses `dotnet build Aspire.slnx --no-incremental /p:UpdateConfigurationSchema=true`;
Mac uses `./build.sh --restore --build /p:UpdateConfigurationSchema=true`.
It happens only in the owned clone, with source status/diff captured, never by
changing the real checkout's `global.json`, package manifests or NuGet config.
No validation is disabled to pass.

Only the build child is timed. Windows records unrounded monotonic wall seconds;
Mac retains upstream `/usr/bin/time -p` real/user/sys output. Adapter startup and
setup/clean/restore are outside the timed interval. No all-native compiler claim
is made: native host/PowerShell are verified, other tools and x64 protoc may differ.

Default timed commands are recipe-exact and may not emit binary logs. When the
original wrapper emits its own binlogs, fresh logs are copied per iteration before
the next clean/build can overwrite them. Add
`-DiagnosticBinlogs` to append `/bl:<owned-path>` to timed builds. This **declared
instrumentation changes the command/overhead**; compare only equally instrumented
runs, not these numbers against uninstrumented upstream HOBL. Binlog-enabled
results reject missing/empty binlogs. Source-generated Arcade logs also remain
in the owned clone; no second build is run merely to manufacture evidence.

`result.json`, `metrics.csv` (successful scenarios only), command JSON, separate
stdout/stderr, provenance scripts, hardware, setup and per-iteration logs preserve
failures as well as successes. A pass requires successful clean/restore/build
phases, nonzero timing, actual compiler output/work and fresh build artifacts;
exit zero alone is insufficient. Four completed validated iterations are required
for `completeFourLoopResult: true`. `compiler_invocations` is null/unavailable:
`compiler_command_lines_observed` counts only stdout mentions, with an explicit
capture kind. Fresh obj/bin DLL counts are file counts, not compiler or unique
project counts. Review logs/binlogs for that analysis.
Existing/source sentinels and recursive no-reparse-point checks guard clean
confinement. A generated symlink/junction is a safety blocker, not silently allowed.

Each future run copies the adapter scripts/helpers/manifest into
`provenance\adapter` before setup. A late copy of current code cannot establish
which harness executed an older measurement; snapshots made after measurement
must be labeled as current-candidate captures, not reconstructed historical proof.

## CI isolation

The already-registered `compare-arm64-developer-build.yml` filename is a tiny
manual dispatcher **only on this isolated branch**; it calls the same-branch
reusable `hobl-aspire.yml`. Both are job-gated to `yeelam-gordon/aspire`, branch
`perf/hobl-aspire`. There are no push/PR/schedule triggers. One invocation chooses one
profile and runs one Windows ARM64 and one Mac job, with a 60-minute job limit,
independent failures, read-only contents and unconditional log/artifact upload.
The same scripts are used locally and in CI. There is no regular PR consumer,
so no test-trigger-map routing change is needed.

**Actions is currently disabled on the owned fork; CI is unexecuted.** Do not
change settings, bypass that restriction, use another repository, or dispatch
until separately authorized. For future authorized use only (not executed here):

```powershell
gh workflow run compare-arm64-developer-build.yml --repo yeelam-gordon/aspire --ref perf/hobl-aspire -f profile=original -f loops=4 -f diagnostic_binlogs=false
```

An aligned run changes `profile=aligned`. The registered workflow ID is
`400645444` (as verified by the owning session). A newly added dispatch filename
on a feature branch alone is not registered: do not claim direct dispatch to
`hobl-aspire.yml` works until that filename exists on the default branch. The
registered dispatcher avoids changing fork main, repository settings, or upstream.
See [GitHub's workflow_dispatch registration requirement](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_dispatch).
The command above requires the isolated branch to be published and Actions
to be separately authorized/enabled. The adapter itself never pushes, submits
a PR, changes settings or dispatches CI. Workflow/action policy admission remains
unverified until authorized execution; a static check is not a passed CI result.
