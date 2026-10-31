#!/usr/bin/env python3
"""Verify pinned external Hazel fixtures, then run the complete Swift test suite.

Each source checkout path must be provided in the environment named in the
manifest. Related aliases and a dedicated test Trash are also mandatory, so tests
cannot silently skip because a corpus variable was omitted.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
manifest = json.loads((repo / "Tests/Fixtures/hazel-corpus-manifest.json").read_text())
errors = []
roots = {}
for source in manifest["sources"]:
    name = source["env"]
    value = os.environ.get(name)
    if not value:
        errors.append(f"{name} is required ({source['url']} at {source['revision']})")
        continue
    root = Path(value).resolve()
    roots[name] = root
    try:
        revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        errors.append(f"{name} is not a Git checkout: {root}")
        continue
    if revision != source["revision"]:
        errors.append(f"{name} has revision {revision}; expected {source['revision']}")
    for relative, expected in source["files"].items():
        path = root / relative
        try:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as error:
            errors.append(f"Cannot read {name}/{relative}: {error}")
            continue
        if actual != expected:
            errors.append(f"Fixture hash mismatch: {name}/{relative}")

def require_alias(name, expected):
    value = os.environ.get(name)
    if not value:
        errors.append(f"{name} is required")
    elif expected is not None and Path(value).resolve() != expected.resolve():
        errors.append(f"{name} must refer to {expected}")

require_alias("FOREL_HAZEL_TUX", roots.get("FOREL_HAZEL_TUXPEOPLE", Path("/nonexistent")) / "files/Hazel/hazelrules")
corpus_root = os.environ.get("FOREL_HAZEL_SHELL_CORPUS")
if not corpus_root:
    errors.append("FOREL_HAZEL_SHELL_CORPUS is required")
else:
    for variable, child in [("FOREL_HAZEL_OPEN_URL", "hazel-open-url"), ("FOREL_HAZEL_UNZIP", "hazel-unzip")]:
        if variable in roots and (Path(corpus_root) / child).resolve() != roots[variable]:
            errors.append(f"FOREL_HAZEL_SHELL_CORPUS/{child} must refer to {variable}")
extras = os.environ.get("FOREL_HAZEL_SHELL_EXTRAS")
if not extras:
    errors.append("FOREL_HAZEL_SHELL_EXTRAS is required")
else:
    for variable, child in [("FOREL_HAZEL_HEIC", "forel-hazel-heic2jpg"), ("FOREL_HAZEL_WRAPPED", "forel-hazel-jaxfry")]:
        if variable in roots and (Path(extras) / child).resolve() != roots[variable]:
            errors.append(f"FOREL_HAZEL_SHELL_EXTRAS/{child} must refer to {variable}")
trash = Path(os.environ.get("FOREL_TEST_TRASH_DIRECTORY", ""))
resolved_trash = trash.resolve()
tmp_root = Path("/tmp").resolve()
if not os.environ.get("FOREL_TEST_TRASH_DIRECTORY") or trash.is_symlink() or not trash.is_dir() or not resolved_trash.is_relative_to(tmp_root) or not resolved_trash.relative_to(tmp_root).parts or not resolved_trash.relative_to(tmp_root).parts[0].startswith("forel-hazel-"):
    errors.append("FOREL_TEST_TRASH_DIRECTORY must be an existing non-symlink directory under /tmp/forel-hazel-...")
if errors:
    print("Hazel fixture verification failed:\n" + "\n".join(f"- {error}" for error in errors), file=sys.stderr)
    sys.exit(2)
print(f"Verified {sum(len(source['files']) for source in manifest['sources'])} pinned Hazel exports.", flush=True)
arguments = sys.argv[1:]
if any(arg in ("--configuration=release", "-c=release") or (arg in ("--configuration", "-c") and index + 1 < len(arguments) and arguments[index + 1] == "release") for index, arg in enumerate(arguments)):
    sys.exit("The corpus tests require a debug build for the dedicated test Trash override")
test_env = os.environ.copy()
if arguments[:1] == ["--audit"]:
    test_env["FOREL_HAZEL_AUDIT"] = "1"
    descriptor, audit_path = tempfile.mkstemp(prefix="forel-hazel-audit-", suffix=".jsonl", dir="/tmp")
    os.close(descriptor)
    test_env["FOREL_HAZEL_AUDIT_OUTPUT"] = audit_path
    print(f"Audit report: {audit_path}", flush=True)
    arguments = ["--filter", "HazelCorpusAuditTests", *arguments[1:]]
sys.exit(subprocess.call(["swift", "test", *arguments], cwd=repo, env=test_env))
