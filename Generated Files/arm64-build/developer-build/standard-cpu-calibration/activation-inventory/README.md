# P50 actual-image activation inventory, read-only

One manual Windows ARM64 job, five-minute bound, exact owned branch and
attempt1. Local preparation only: no push/dispatch selected here.
No SDK bootstrap/install/restore, product checkout/build/warm-up, profiling,
COM activation, registry write/repair, service action or tracing.

The only CLI invocation is the fixed installed `VSDiagnostics.exe` with
exact argv `start /help`. No executable/argument override exists in the
adapter; the independently tested validator rejects session/status/stop,
foreign executable and extra arguments. Public IsWow64Process2 observes
only that owned child's handle; PID/birth/path, streams and exit are retained.

Uploaded properties are limited to image/OS/shell architecture/elevation,
three public interop GUID declarations/PE flags, fixed Host CLSID/AppID
LocalService in explicit HKLM/HKCU64/32 views, exact service ImagePath/Start/
PE/version, and own help identity/architecture. No vendor binary, proprietary
manifest/implementation body, usernames/SIDs, unowned process or event data.

Registry keys are opened read-only. Registry32/64 labels do not imply all
ARM32/x86 physical views or HKCR/elevation merging have been resolved.
`PresentStaticRoute` is NOT successful activation; missing states are explicit
inventory findings, never default readiness. Service ImagePath outside the
exact component allowlist is recorded but not followed/read/executed.

Probe exceptions and incomplete results are closed JSON under the single
`activation-inventory-results` upload root before failing. The always upload
retains them; no broad home/checkout/SDK/scratch upload.
The focused test inserts a real own output-path collision after the fixed help
probe begins: original probe error, incomplete inventory and own-child exit
proof survive. Snapshot/reporting errors are separate and do not silently
discard other probes or promote incomplete results.

Use the separate local adapter without fabricating a GitHub environment:

```powershell
& .\Invoke-LocalInventory.ps1 -Output <new-owned-output>
& .\Test-Inventory.ps1 -Output <new-owned-test-output>
```

Only public metadata APIs are used, not vendor assembly execution/private
implementation inspection. Known host GUID:
F2DC0F57-0B99-49E3-BE80-936DBAA54EE0; service interface IID:
7AE366C7-E696-4178-98D0-DD8D48CD5E44. No absent CPU-agent/service-class
registration is turned into a missing-class diagnosis.

If the static Host route is present, the exact nested CreateSession failing
CLSID/CLSCTX remains unknown. Vendor-correlated failing activation identity,
context/architecture and HRESULT are still required; no further profile or
repair is implied. Public sources:
[registry views](https://learn.microsoft.com/windows/win32/winprog64/registry-redirector),
[LocalService](https://learn.microsoft.com/windows/win32/com/localservice),
[process architecture](https://learn.microsoft.com/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2).

All files are descendants of the existing dedicated/manual
`standard-cpu-calibration/**` classification; the registered workflow keeps
its existing generic Infrastructure.Tests route. No new PR target/map needed.
