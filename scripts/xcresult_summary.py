#!/usr/bin/env python3
"""
#204 (C2) — summarise an .xcresult: which tests failed, and which only passed on a retry.

With `-retry-tests-on-failure`, xcodebuild re-runs just the failing test instead of the whole
suite. A test that failed and then passed is FLAKY: the run is green, but it's listed here (and in
the GitHub job summary) so it gets an issue rather than quietly costing a retry on every run.

Usage: xcresult_summary.py <path.xcresult> <label>
"""
import json
import os
import subprocess
import sys


def walk(node, path, out):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Case":
        reps = [c for c in node.get("children", []) if c.get("nodeType") == "Repetition"]
        failed_reps = [r for r in reps if r.get("result") == "Failed"]
        result = node.get("result")
        full = "/".join(path + [name])
        if result == "Failed":
            out["failed"].append(full)
        elif failed_reps and result == "Passed":
            out["flaky"].append(f"{full} (passed on attempt {len(reps)} of {len(reps)})")
        return
    for child in node.get("children", []):
        walk(child, path + ([name] if kind in ("Test Suite", "Unit test bundle", "UI test bundle") else []), out)


def main():
    bundle, label = sys.argv[1], sys.argv[2]
    raw = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                         capture_output=True, text=True)
    if raw.returncode != 0:
        print(f"    (no test results in {bundle}: {raw.stderr.strip()[:200]})")
        return
    out = {"failed": [], "flaky": []}
    for node in json.loads(raw.stdout).get("testNodes", []):
        walk(node, [], out)

    lines = []
    if out["flaky"]:
        lines.append(f"**{label}: {len(out['flaky'])} flaky test(s)** — failed, then passed on retry. File an issue:")
        lines += [f"- `{t}`" for t in out["flaky"]]
    if out["failed"]:
        lines.append(f"**{label}: {len(out['failed'])} failed test(s):**")
        lines += [f"- `{t}`" for t in out["failed"]]
    if not lines:
        lines.append(f"{label}: every test passed on its first attempt.")
    text = "\n".join(lines)
    print("\n".join("    " + l for l in text.splitlines()))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(text + "\n\n")


if __name__ == "__main__":
    main()
