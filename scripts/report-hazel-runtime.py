#!/usr/bin/env python3
"""Render the checked-in scenario inventory against a strict corpus audit.

The inventory describes test coverage, not an assertion that tests ran. Run
the complete verified suite before presenting this report as a test result.
"""
import collections
import json
from pathlib import Path
import sys

if len(sys.argv) != 2:
    sys.exit("usage: python3 scripts/report-hazel-runtime.py AUDIT.jsonl")
repo = Path(__file__).resolve().parent.parent
coverage = json.loads((repo / "Tests/Fixtures/hazel-runtime-coverage.json").read_text())["rules"]
audit = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
identity = lambda row: (row["source"], row["file"], row["rule"])
actual = [row for row in audit if "rule" in row]
if any("importFailure" in row for row in audit):
    sys.exit("Audit contains import failures")
if len({identity(row) for row in coverage}) != len(coverage) or {identity(row) for row in actual} != {identity(row) for row in coverage}:
    sys.exit("Runtime inventory does not match the current pinned audit")
blocked = {identity(row) for row in actual if row.get("blocked")}
counts = collections.Counter(row["status"] for row in coverage)
print("# Pinned Hazel runtime scenario inventory\n")
print(f"{len(coverage)} rules; {len(blocked)} blocked in the supplied import audit. "
      "This inventory identifies tests and their substitutions; it is not proof that those tests ran.\n")
for status, count in sorted(counts.items()):
    print(f"- {status}: {count}")
original_sources = {"FOREL_HAZEL_CORPUS", "FOREL_HAZEL_CORPUS_2", "FOREL_HAZEL_BJANGO"}
original = [row for row in coverage if row["source"] in original_sources]
original_counts = collections.Counter(row["status"] for row in original)
print(f"\nOriginal collections: {len(original)} rules; " + ", ".join(f"{count} {status}" for status, count in sorted(original_counts.items())) + ".")
print("\n| Source | Export | Rule | Scenario | Evidence | Details |\n| --- | --- | --- | --- | --- | --- |")
for row in sorted(coverage, key=identity):
    fields = [row["source"], row["file"], row["rule"], row["status"], row["test"], row["details"]]
    print("| " + " | ".join(str(field).replace("|", "\\|").replace("\n", " ") for field in fields) + " |")
