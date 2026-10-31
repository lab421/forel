# Hazel corpus tests

`hazel-corpus-manifest.json` pins each public repository revision and the SHA-256
of every rule export exercised by the external corpus suite. The sources are
intentionally not bundled: Hazel exports can contain personal paths and scripts.

Check out each repository at the revision in the manifest and set its named
`FOREL_HAZEL_*` environment variable to that checkout. Also set:

- `FOREL_HAZEL_TUX` to the `files/Hazel/hazelrules` folder inside the TUXPEOPLE checkout.
- `FOREL_HAZEL_SHELL_CORPUS` to a directory containing the OPEN_URL and UNZIP checkouts, named `hazel-open-url` and `hazel-unzip`.
- `FOREL_HAZEL_SHELL_EXTRAS` to a directory containing the HEIC and WRAPPED checkouts, named `forel-hazel-heic2jpg` and `forel-hazel-jaxfry`.
- `FOREL_TEST_TRASH_DIRECTORY` to an existing, non-symlink directory under `/tmp/forel-hazel-...`. Debug builds use this dedicated directory for Trash actions.

Then run `python3 scripts/test-hazel-corpus.py`. Arguments are forwarded to
`swift test`, for example `--filter HazelPatternTests`. The runner refuses to
start if any source, revision, file hash, alias, or dedicated test Trash is missing,
so a passing corpus run cannot silently skip a fixture because its environment
variable was unset. The runner requires a debug build so the test Trash override is active. It does not execute imported scripts merely to verify them;
individual tests use controlled substitutes or explicitly reviewed scripts.
Use `python3 scripts/test-hazel-corpus.py --audit` for a JSON-lines report of
every pinned export and rule, including blocking omissions, review issues,
action and condition kinds, and external runtime dependencies. The runner prints
the report path under `/tmp`; the final JSON line contains totals. Import failures make the
audit fail. Unrecognized rule, action, predicate, and predicate-operator fields
are explicitly reported and block the affected rule.

After a strict audit, pass its printed JSON-lines path to
`python3 scripts/report-hazel-runtime.py /path/to/audit.jsonl` to render the
55-rule scenario inventory. The renderer checks that every audited rule has an
inventory entry. Scenario names identify tests and substitutions; they are not
evidence that the tests ran or passed in the current environment.

Alternatively, with the dedicated test Trash described above, run
`python3 scripts/setup-hazel-corpus.py`. It clones the pinned public
repositories into a new directory under `/tmp`, configures the corpus aliases,
extracts and verifies only the pinned HEIC rule from its ZIP, and invokes the
same strict verifier and test suite. Pass Swift test arguments after `--`.
Pass `-- --audit` to run the audit instead of the full suite.
`--root /tmp/forel-hazel-fixtures-...` reuses existing checkouts only when they
already have the pinned revisions; the setup never resets an existing checkout.

For the complete local upload integration tests, create a disposable Python
environment with the pinned test-only server dependencies and run the corpus
setup inside the upload harness. The harness creates temporary SSH keys and a
localhost `sshd`, then cleans them up; FTP/FTPS and password-authentication
servers are also bound to localhost by the tests. No existing SSH configuration
or account password is changed. This requires macOS, the system SSH server,
Python 3, and access to install the listed packages and clone the pinned corpus.

```sh
python3 -m venv /tmp/forel-hazel-upload-venv
/tmp/forel-hazel-upload-venv/bin/python -m pip install 'paramiko==3.5.1' 'pyftpdlib==2.0.1' 'pyOpenSSL==25.1.0'
test_trash=$(mktemp -d /tmp/forel-hazel-trash.XXXXXX)
env FOREL_TEST_TRASH_DIRECTORY="$test_trash" \
  FOREL_UPLOAD_TEST_PYTHON=/tmp/forel-hazel-upload-venv/bin/python \
  FOREL_AUTOMATOR_INTEGRATION=1 \
  bash scripts/test-upload-integration.sh python3 scripts/setup-hazel-corpus.py -- --disable-sandbox
```

Set `FOREL_AUTOMATOR_INTEGRATION=1` as shown to exercise a locally constructed,
harmless Automator workflow; omit it to skip that optional system integration.
The upload harness requires the Python environment and its three dependencies:
it stops with an error if they are missing, rather than silently skipping the
network integration tests. Run outside a restrictive sandbox when localhost
listeners, the system automation runtimes, or Finder metadata are unavailable.
