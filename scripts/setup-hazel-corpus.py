#!/usr/bin/env python3
"""Fetch the pinned public Hazel corpus to /tmp and run the strict verifier."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", help="Existing or new corpus directory under /tmp; defaults to a fresh directory")
parser.add_argument("swift_test_args", nargs=argparse.REMAINDER, help="Arguments forwarded after -- to swift test")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
manifest = json.loads((repo / "Tests/Fixtures/hazel-corpus-manifest.json").read_text())
trash_setting = os.environ.get("FOREL_TEST_TRASH_DIRECTORY", "")
trash = Path(trash_setting)
resolved_trash = trash.resolve()
tmp_root = Path("/tmp").resolve()
if not trash_setting or trash.is_symlink() or not trash.is_dir() or not resolved_trash.is_relative_to(tmp_root) or not resolved_trash.relative_to(tmp_root).parts or not resolved_trash.relative_to(tmp_root).parts[0].startswith("forel-hazel-"):
    sys.exit("FOREL_TEST_TRASH_DIRECTORY must be an existing non-symlink directory under /tmp/forel-hazel-...; use a debug build.")
root = Path(args.root).resolve() if args.root else Path(tempfile.mkdtemp(prefix="forel-hazel-fixtures-", dir="/tmp")).resolve()
if not root.is_relative_to(Path("/tmp").resolve()) or root == Path("/tmp").resolve():
    sys.exit("The fixture root must be a dedicated directory under /tmp.")
root.mkdir(parents=True, exist_ok=True)
names = {
    "FOREL_HAZEL_CORPUS": "hazel-samples", "FOREL_HAZEL_CORPUS_2": "hazel-samples-2",
    "FOREL_HAZEL_CORPUS_3": "hazel-samples-3", "FOREL_HAZEL_BJANGO": "hazel-bjango",
    "FOREL_HAZEL_INSTALLER": "hazel-installer", "FOREL_HAZEL_OPEN_URL": "hazel-open-url",
    "FOREL_HAZEL_PHOTOS": "hazel-photos", "FOREL_HAZEL_TICKLER": "hazel-tickler",
    "FOREL_HAZEL_UNZIP": "hazel-unzip", "FOREL_HAZEL_TUXPEOPLE": "hazel-tuxpeople",
    "FOREL_HAZEL_HEIC": "forel-hazel-heic2jpg", "FOREL_HAZEL_WRAPPED": "forel-hazel-jaxfry",
}
child_env = os.environ.copy()
git_env = child_env.copy()
git_env["GIT_CONFIG_NOSYSTEM"] = "1"
git_env["GIT_CONFIG_GLOBAL"] = os.devnull
git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=never"]
for source in manifest["sources"]:
    name, url, revision = source["env"], source["url"], source["revision"]
    if name not in names or not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", url) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        sys.exit(f"Unsafe or invalid manifest source: {name}")
    target = root / names[name]
    if target.is_symlink():
        sys.exit(f"Refusing symlink checkout: {target}")
    if not target.exists():
        subprocess.run([*git, "clone", "--no-checkout", "--filter=blob:none", "--no-tags", "--", url, str(target)], check=True, env=git_env)
        subprocess.run([*git, "-C", str(target), "checkout", "--detach", revision], check=True, env=git_env)
    else:
        current = subprocess.check_output([*git, "-C", str(target), "rev-parse", "HEAD"], text=True, env=git_env).strip()
        if current != revision:
            sys.exit(f"Existing checkout {target} is at {current}, expected {revision}; it was not changed.")
    child_env[name] = str(target)
    if name == "FOREL_HAZEL_HEIC":
        output = target / "Downloads-HEIC2jpg.hazelrules"
        expected = source["files"][output.name]
        if not output.exists():
            with zipfile.ZipFile(target / "Downloads-HEIC2jpg.hazelrules.zip") as archive:
                matches = [item for item in archive.infolist() if item.filename == output.name]
                if len(matches) != 1 or matches[0].file_size > 20 * 1024 * 1024 or not stat.S_ISREG(matches[0].external_attr >> 16):
                    sys.exit("The HEIC export archive has an invalid or oversized member.")
                payload = archive.read(matches[0])
            if hashlib.sha256(payload).hexdigest() != expected:
                sys.exit("The HEIC export member does not match the pinned hash.")
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
child_env["FOREL_HAZEL_TUX"] = str(root / names["FOREL_HAZEL_TUXPEOPLE"] / "files/Hazel/hazelrules")
child_env["FOREL_HAZEL_SHELL_CORPUS"] = str(root)
child_env["FOREL_HAZEL_SHELL_EXTRAS"] = str(root)
forward = args.swift_test_args[1:] if args.swift_test_args[:1] == ["--"] else args.swift_test_args
print(f"Fixture checkouts: {root}", flush=True)
os.execve(sys.executable, [sys.executable, str(repo / "scripts/test-hazel-corpus.py"), *forward], child_env)
