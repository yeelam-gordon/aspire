"""Bounded manual-workflow safety checks; requires the existing PyYAML parser."""

import pathlib
import re
import subprocess

import yaml


root = pathlib.Path(__file__).resolve().parents[4]
workflow_path = ".github/workflows/compare-arm64-developer-build.yml"
text = (root / pathlib.PurePosixPath(workflow_path)).read_text(encoding="utf-8")
workflow = yaml.load(text, Loader=yaml.BaseLoader)
assert list(workflow["on"]) == ["workflow_dispatch"]
assert workflow["permissions"] == {"contents": "read"}
assert len(workflow["jobs"]) == 1
job = workflow["jobs"]["paired_pgo"]
assert job["strategy"] == {
    "fail-fast": "false",
    "matrix": {"runner": ["windows-11-vs2026-arm", "macos-latest"]},
}
assert job["timeout-minutes"] == "30"
guard = job["if"]
assert re.fullmatch(
    r"\s*github\.repository == 'yeelam-gordon/aspire' &&\s*"
    r"github\.ref == 'refs/heads/perf/arm64-compiler-pgo'\s*",
    guard,
)
steps = job["steps"]
assert steps[0]["name"] == "Precreate evidence and ownership epoch"
assert "PAIRED_JOB_START_UTC" in steps[0]["run"]
checkouts = [s for s in steps if s.get("uses", "").startswith("actions/checkout@")]
assert len(checkouts) == 2
assert checkouts[0]["with"] == {
    "path": "instrumentation",
    "persist-credentials": "false",
}
assert checkouts[1]["with"] == {
    "ref": "06efc928e31486923754398007f4f78003e04ee3",
    "path": "product",
    "persist-credentials": "false",
}
bootstrap = next(s["run"] for s in steps if s["name"].startswith("Restore fresh"))
assert "Test-PairedDispatch" in bootstrap
assert "Test-Path (Join-Path $root '.dotnet')" in bootstrap
assert "$root = Join-Path $PWD 'product'" in bootstrap
assert "$project = Join-Path $root" in bootstrap
assert "-projects $project" in bootstrap
assert "jobStartUtc = $env:PAIRED_JOB_START_UTC" in bootstrap
measurement = next(s["run"] for s in steps if s["name"] == "One paired block on this host")
assert re.search(r"(?m)^\s*-EditCount 8\s*$", measurement)
assert measurement.count("-EditCount") == 1
assert "-LocalSmoke" not in measurement
upload = steps[-1]
assert upload["if"] == "always()"
assert upload["with"]["if-no-files-found"] == "error"
assert "compiler-pgo-results/" in upload["with"]["path"]
assert all("uses" not in s or re.fullmatch(r".+@[0-9a-f]{40}", s["uses"]) for s in steps)
baseline = subprocess.check_output(
    ["git", "-C", str(root), "show",
     "891d5a172210ae8fa1c7b1ea31ff86f12dc0a838:" + workflow_path],
    text=True,
)
assert re.findall(r"uses:\s*(\S+)", text) == re.findall(r"uses:\s*(\S+)", baseline)
harness = (pathlib.Path(__file__).parent / "Measure-PairedPgo.ps1").read_text(encoding="utf-8")
assert "Test-PairedInvocation $env:GITHUB_REPOSITORY $env:GITHUB_REF $env:GITHUB_EVENT_NAME $source" in harness
assert re.search(r"\[ValidateSet\(1,\s*8\)\]\[int\]\$EditCount\s*=\s*8", harness)
assert "$expectedCases = 4 * (2 + $EditCount)" in harness
assert "$receipts.Count -ne $expectedCases" in harness
assert harness.count("1..$EditCount") == 2
assert "Get-NativeImageIdentity" in harness
assert "Get-PairedRuntimeImageHeader $bytes $IsWindows" in harness
assert "ConvertFrom-PairedMacState" in harness
assert "Test-PairedAbsence" in harness
assert not re.search(r"build-server\s+shutdown|Stop-Process\s+-Name|taskkill", harness, re.I)
assert "/p:UseSharedCompilation" not in harness and "/nr:" not in harness
print("YAML/manual/fork/ref/exact-source/unchanged-pins/native-bootstrap/ownership/always-upload source checks passed.")
