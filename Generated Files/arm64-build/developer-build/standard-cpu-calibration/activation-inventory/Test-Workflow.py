import json
import pathlib
import sys

import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert workflow["permissions"] == {"contents": "read"}
assert len(workflow["jobs"]) == 1
job = workflow["jobs"]["activation_inventory"]
assert job["timeout-minutes"] == 5
assert job["runs-on"] == "windows-11-vs2026-arm"
steps = job["steps"]
assert len(steps) == 3
assert steps[0]["uses"] == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
assert steps[0]["with"] == {"persist-credentials": False}
assert steps[2]["uses"] == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
assert steps[2]["if"] == "always()"
assert steps[2]["with"]["path"] == "activation-inventory-results/"
assert "Invoke-HostedInventory.ps1" in steps[1]["run"]
assert "refs/heads/perf/arm64-activation-inventory" in job["if"]
assert "github.run_attempt == 1" in job["if"]
print(json.dumps({"passed": True, "oneReadOnlyJob": True, "minutes": 5,
                  "pinsUnchanged": True, "exactUploadRoot": True}))
