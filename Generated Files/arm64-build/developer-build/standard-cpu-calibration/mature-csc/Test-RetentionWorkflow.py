import json
import pathlib
import sys

import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
job = workflow["jobs"]["mature_cpu"]
steps = job["steps"]
uploads = [(i, s) for i, s in enumerate(steps) if s.get("uses", "").startswith("actions/upload-artifact@")]
assert len(uploads) == 2, "independent metadata and raw artifacts required"
(meta_index, metadata), (raw_index, raw) = uploads
assert meta_index < raw_index
assert metadata["if"] == "always()"
assert metadata["with"]["path"] == "mature-cpu-results/retained/metadata/"
assert raw["with"]["path"] == "mature-cpu-results/retained/raw/"
assert "steps.stage.outputs.raw_files_available" in raw["if"]
assert "always()" in raw["if"]
stage = [(i, s) for i, s in enumerate(steps) if s.get("id") == "stage"]
assert len(stage) == 1 and stage[0][0] < meta_index and stage[0][1]["if"] == "always()"
assert "evidence/" not in metadata["with"]["path"] and "evidence/" not in raw["with"]["path"]
assert job["timeout-minutes"] == 20
assert job["runs-on"] == "windows-11-vs2026-arm"
print(json.dumps({"passed": True, "metadataBeforeRaw": True, "exactIsolatedRoots": True,
                  "stagingBeforeMetadata": True, "rawConditionalOnSafeFiles": True}))
