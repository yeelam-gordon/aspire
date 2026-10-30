$ErrorActionPreference = 'Stop'
function Test-MatureContext($Context)
{
    return $Context.actions -ceq 'true' -and $Context.repository -ceq 'yeelam-gordon/aspire' -and
        $Context.ref -ceq 'refs/heads/perf/arm64-mature-cpu-profile' -and $Context.event -ceq 'workflow_dispatch' -and
        $Context.runnerEnvironment -ceq 'github-hosted' -and $Context.runnerOS -ceq 'Windows' -and
        $Context.runnerArch -ceq 'ARM64' -and $Context.imageOS -ceq 'win11-vs2026-arm64' -and
        $Context.osArch -ceq 'Arm64' -and $Context.processArch -ceq 'Arm64' -and
        $Context.runId -match '^\d+$' -and $Context.runAttempt -ceq '1'
}
function Assert-MatureContext
{
    $context = @{
        actions=$env:GITHUB_ACTIONS; repository=$env:GITHUB_REPOSITORY; ref=$env:GITHUB_REF
        event=$env:GITHUB_EVENT_NAME; runnerEnvironment=$env:RUNNER_ENVIRONMENT; runnerOS=$env:RUNNER_OS
        runnerArch=$env:RUNNER_ARCH; imageOS=$env:ImageOS; runId=$env:GITHUB_RUN_ID; runAttempt=$env:GITHUB_RUN_ATTEMPT
        osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    if (-not (Test-MatureContext $context)) { throw 'P49 capture requires exact owned/manual/ref/first-attempt hosted Windows ARM64; no local override.' }
    $workspace=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')+'\'
    if (-not $PSScriptRoot.StartsWith($workspace,[StringComparison]::OrdinalIgnoreCase) -or
        (& git -C $PSScriptRoot rev-parse HEAD).Trim() -cne $env:GITHUB_SHA)
    { throw 'Instrumentation workspace/dispatched SHA mismatch.' }
    return $context
}
