# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

"""Optional parsed YAML validation; requires existing PyYAML, never installs it."""

from pathlib import Path

import yaml


root = Path(__file__).resolve().parents[3] / ".github" / "workflows"
# BaseLoader retains Actions' `on` key instead of treating it as YAML 1.1 true.
dispatcher = yaml.load(
    (root / "compare-arm64-developer-build.yml").read_text(), Loader=yaml.BaseLoader
)
worker = yaml.load((root / "hobl-aspire.yml").read_text(), Loader=yaml.BaseLoader)
assert set(dispatcher["on"]) == {"workflow_dispatch"}
assert set(worker["on"]) == {"workflow_dispatch", "workflow_call"}
inputs = dispatcher["on"]["workflow_dispatch"]["inputs"]
assert set(inputs) == {"profile", "loops", "diagnostic_binlogs"}
for name, kind in [
    ("profile", "string"),
    ("loops", "string"),
    ("diagnostic_binlogs", "boolean"),
]:
    reusable_input = worker["on"]["workflow_call"]["inputs"][name]
    assert reusable_input["type"] == kind
    assert reusable_input["default"] == inputs[name]["default"]
    assert dispatcher["jobs"]["hobl"]["with"][name] == "${{ inputs." + name + " }}"
    dispatch_input = worker["on"]["workflow_dispatch"]["inputs"][name]
    for field in ("type", "default", "options"):
        assert dispatch_input.get(field) == inputs[name].get(field)
assert inputs["profile"]["options"] == ["original", "aligned"]
assert inputs["loops"]["options"] == ["4", "1"]
assert (
    dispatcher["jobs"]["hobl"]["uses"] == "./.github/workflows/hobl-aspire.yml"
)
guard = (
    "github.repository == 'yeelam-gordon/aspire' && "
    "github.ref == 'refs/heads/perf/hobl-aspire'"
)
for document in (dispatcher, worker):
    assert document["permissions"] == {"contents": "read"}
    assert document["jobs"]["hobl"]["if"] == guard
job = worker["jobs"]["hobl"]
assert job["timeout-minutes"] == "60"
assert job["strategy"]["fail-fast"] == "false"
assert job["strategy"]["matrix"]["include"] == [
    {"os": "windows", "runner": "windows-11-vs2026-arm"},
    {"os": "macos", "runner": "macos-latest"},
]
upload = job["steps"][-1]
assert upload["if"] == "always()"
assert upload["uses"] == (
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
)
print("PASS: parsed dispatcher/reusable workflow isolation, inputs and native pair")
