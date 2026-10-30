"""Manual-only calibration guards; no product builds, runner claims or dispatch."""

import pathlib
import re
import subprocess

import yaml

root = pathlib.Path(__file__).resolve().parents[4]
relative = ".github/workflows/compare-arm64-developer-build.yml"
text = (root / pathlib.PurePosixPath(relative)).read_text(encoding="utf-8")
workflow = yaml.load(text, Loader=yaml.BaseLoader)
assert list(workflow["on"]) == ["workflow_dispatch"]
assert workflow["permissions"] == {"contents": "read"}
assert list(workflow["jobs"]) == ["paired_warmup"]
job = workflow["jobs"]["paired_warmup"]
assert job["strategy"] == {
    "fail-fast": "false",
    "matrix": {"runner": ["windows-11-vs2026-arm", "macos-latest"]},
}
assert job["timeout-minutes"] == "30"
assert re.fullmatch(
    r"\s*github\.repository == 'yeelam-gordon/aspire' &&\s*"
    r"github\.ref == 'refs/heads/perf/arm64-compiler-warmup'\s*", job["if"]
)
steps = job["steps"]
assert steps[0]["name"] == "Precreate evidence and ownership epoch"
assert "PAIRED_JOB_START_UTC" in steps[0]["run"]
checkouts = [s for s in steps if s.get("uses", "").startswith("actions/checkout@")]
assert len(checkouts) == 2
assert checkouts[0]["with"] == {"path": "instrumentation", "persist-credentials": "false"}
assert checkouts[1]["with"] == {
    "ref": "06efc928e31486923754398007f4f78003e04ee3",
    "path": "product", "persist-credentials": "false",
}
bootstrap = next(s["run"] for s in steps if s["name"].startswith("Restore fresh"))
assert "$project = Join-Path $root" in bootstrap and "-projects $project" in bootstrap
assert "Test-PairedDispatch" in bootstrap
assert "Test-Path (Join-Path $root '.dotnet')" in bootstrap
measurement = next(s["run"] for s in steps if s["name"].startswith("Two default lifetimes"))
assert re.search(r"(?m)^\s*-EditCount 20\s*$", measurement)
assert measurement.count("-EditCount") == 1 and "-LocalSmoke" not in measurement
assert steps[-1]["if"] == "always()"
assert steps[-1]["with"]["if-no-files-found"] == "error"


def validate_upload_roots(upload):
    """Including hidden files is safe only inside these dedicated evidence roots."""
    assert upload["include-hidden-files"] == "true"
    paths = [line.strip() for line in upload["path"].splitlines() if line.strip()]
    assert len(paths) == len(set(paths)) == 2
    assert set(paths) == {"compiler-warmup-results/", "product/artifacts/log/"}


validate_upload_roots(steps[-1]["with"])
for bad_path in (".", "./", "product/", "instrumentation/", ".git/", "~/", "/Users/runner/",
                 "compiler-warmup-results/../../", "product/artifacts/log/**", "!product/.git/"):
    candidate = dict(steps[-1]["with"])
    candidate["path"] = "compiler-warmup-results/\n" + bad_path
    try:
        validate_upload_roots(candidate)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"Uncontrolled hidden upload accepted: {bad_path}")
baseline = subprocess.check_output(
    ["git", "-C", str(root), "show", "4bdcfc201670d1dcb6cf4df80dc7259502713ded:" + relative],
    text=True,
)
assert re.findall(r"uses:\s*(\S+)", text) == re.findall(r"uses:\s*(\S+)", baseline)
harness = (pathlib.Path(__file__).parent / "Measure-PairedWarmup.ps1").read_text(encoding="utf-8")
cleanup = (pathlib.Path(__file__).parent / "Paired-Cleanup.ps1").read_text(encoding="utf-8")
assert re.search(r"\[ValidateSet\(1,\s*20\)\]\[int\]\$EditCount\s*=\s*20", harness)
assert "$expectedCases = 2 * (2 + $EditCount)" in harness
assert "$lifetimes = @(1..3)" in harness
assert "if ($diagnostic) { @('cold','edit1','edit2') }" in harness
assert "early = @(1..5); late = @(16..20)" in harness
assert "0x3000000038:5" in harness and "DOTNET_EventPipeCircularMB = '100'" in harness
assert not re.search(r"build-server\s+shutdown|Stop-Process\s+-Name|taskkill", harness + cleanup, re.I)
assert "/p:UseSharedCompilation" not in harness and "/nr:" not in harness
assert "candidate" not in harness.lower() and "New-PgoCandidate" not in harness
assert not re.search(r"WriteAllBytes\(\$config|SetLastWriteTimeUtc\(\$config", harness)
assert "Get-PairedRuntimeImageHeader $bytes $IsWindows" in harness
assert "ConvertFrom-PairedMacState" in harness and "Get-PairedExitState" in cleanup
print("Manual-only YAML, unchanged pins, 44-build A/A, separate 3-build diagnostic, normal-policy and source guards passed.")
