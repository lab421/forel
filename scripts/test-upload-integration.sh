#!/bin/bash
# Run a command with temporary localhost FTP/SFTP integration fixtures enabled.
set -euo pipefail
python=${FOREL_UPLOAD_TEST_PYTHON:?Set FOREL_UPLOAD_TEST_PYTHON to a Python with paramiko, pyftpdlib and OpenSSL installed}
"$python" -c 'import paramiko, pyftpdlib, OpenSSL'
test_root=$(mktemp -d "${TMPDIR:-/tmp}/forel-upload-test.XXXXXX")
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$test_root"
}
trap cleanup EXIT
port=$("$python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$test_root/host"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$test_root/client"
/usr/bin/ssh-keygen -q -t ed25519 -N fixture-secret -f "$test_root/client-encrypted"
cat "$test_root/client.pub" "$test_root/client-encrypted.pub" > "$test_root/authorized_keys"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cat "$test_root/host.pub")" > "$test_root/known_hosts"
cat > "$test_root/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $test_root/host
PidFile $test_root/sshd.pid
AuthorizedKeysFile $test_root/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
EOF
/usr/sbin/sshd -D -e -f "$test_root/sshd_config" > "$test_root/sshd.log" 2>&1 &
server_pid=$!
ready=0
for attempt in {1..50}; do
  if "$python" -c "import socket; s=socket.create_connection(('127.0.0.1',$port),0.1); s.close()" 2>/dev/null; then ready=1; break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$test_root/sshd.log" >&2; exit 1; fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then cat "$test_root/sshd.log" >&2; exit 1; fi
export FOREL_SFTP_REAL_ROOT="$test_root" FOREL_SFTP_REAL_PORT="$port"
export FOREL_SFTP_PARAMIKO_PYTHON="$python" FOREL_FTP_TEST_PYTHON="$python"
if [[ $# -eq 0 ]]; then set -- swift test --disable-sandbox; fi
"$@"
