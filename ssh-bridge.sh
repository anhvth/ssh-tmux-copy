#!/usr/bin/env bash
set -euo pipefail

SSH_BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BASE_DIR="${SSH_BRIDGE_LOCAL_DIR:-$HOME/.cache/ssh-bridge}"
LOCAL_SOCKET="${LOCAL_BASE_DIR}/bridge.sock"
LOCAL_PID="${LOCAL_BASE_DIR}/bridge.pid"
LOCAL_LOG="${LOCAL_BASE_DIR}/bridge.log"
REMOTE_PORT="${SSH_BRIDGE_REMOTE_PORT:-47371}"
REMOTE_STATE_ROOT="${SSH_BRIDGE_REMOTE_STATE_ROOT:-/tmp/ssh-bridge}"

usage() {
    cat <<'USAGE'
Usage:
  ss-bridge bridge {start|serve|stop|status} [--quiet]
  ss-bridge local-command <ssh-config-host> [ssh-user]
  ss-bridge send <request-type> [json-fields]
  ss-bridge code [path] [--vvv]
  ss-bridge open [path] [--vvv]
  ss-bridge copy [--vvv]
  ss-bridge health [ssh-config-host]
  ss-bridge setup <ssh-config-host>

Clients:
  ss-code [path] [--vvv]
  ss-open [path] [--vvv]
  ss-open-remote [path] [--vvv]
  ss-copy < stdin
  ss-pbcopy < stdin
  ss-health [ssh-config-host]
  ss-setup <ssh-config-host>

Remote runtime state lives in /tmp/ssh-bridge/$USER/$HOSTNAME.
Local runtime state lives in ~/.cache/ssh-bridge.
USAGE
}

prog="$(basename "$0")"
case "$prog" in
    ss-code) cmd="code" ;;
    ss-open|ss-open-remote) cmd="open" ;;
    ss-copy|ss-pbcopy) cmd="copy" ;;
    ss-health) cmd="health" ;;
    ss-setup) cmd="setup" ;;
    ss-bridge) cmd="${1:-help}"; [[ $# -gt 0 ]] && shift ;;
    *) cmd="${1:-help}"; [[ $# -gt 0 ]] && shift ;;
esac

choose_code_cmd() {
    if [[ -x /usr/local/bin/code ]]; then echo /usr/local/bin/code; return 0; fi
    if command -v code >/dev/null 2>&1; then command -v code; return 0; fi
    if command -v code-insiders >/dev/null 2>&1; then command -v code-insiders; return 0; fi
    return 1
}

resolve_path() {
    local input="$1" resolved=""
    if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -m "$input" 2>/dev/null || realpath "$input" 2>/dev/null || true)"
    fi
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    elif [[ "$input" == /* ]]; then
        printf '%s\n' "$input"
    else
        printf '%s/%s\n' "$(pwd -P)" "$input"
    fi
}

remote_hostname() {
    hostname 2>/dev/null || printf unknown
}

remote_state_dir() {
    local host
    host="$(remote_hostname)"
    printf '%s\n' "${SSH_BRIDGE_REMOTE_STATE_DIR:-${REMOTE_STATE_ROOT}/${USER:-user}/${host}}"
}

read_first_existing() {
    local file
    for file in "$@"; do
        if [[ -r "$file" ]]; then
            sed -n '1p' "$file" 2>/dev/null || true
            return 0
        fi
    done
    return 0
}

is_remote_shell() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" || -n "${SSH_CLIENT:-}" ]]
}

bridge_python() {
    python3 - "$@" <<'PY'
import argparse
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

base_dir = Path(os.environ["SSH_BRIDGE_LOCAL_DIR"])
socket_path = Path(os.environ["SSH_BRIDGE_LOCAL_SOCKET"])
pid_path = Path(os.environ["SSH_BRIDGE_LOCAL_PID"])
log_path = Path(os.environ["SSH_BRIDGE_LOCAL_LOG"])
script_path = os.environ["SSH_BRIDGE_SCRIPT"]

def which(name):
    for part in os.environ.get("PATH", "").split(os.pathsep):
        if not part:
            continue
        candidate = Path(part) / name
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None

def choose_code_cmd():
    preferred = Path("/usr/local/bin/code")
    if preferred.exists() and os.access(preferred, os.X_OK):
        return str(preferred)
    return which("code") or which("code-insiders")

def choose_clipboard_writer():
    if sys.platform == "darwin" and which("pbcopy"):
        return [which("pbcopy")]
    if os.environ.get("WAYLAND_DISPLAY") and which("wl-copy"):
        return [which("wl-copy")]
    if which("xclip"):
        return [which("xclip"), "-in", "-selection", "clipboard"]
    if which("xsel"):
        return [which("xsel"), "--clipboard", "--input"]
    return None

def choose_opener():
    if sys.platform == "darwin" and Path("/usr/bin/open").exists():
        return ["/usr/bin/open"]
    opener = which("xdg-open")
    if opener:
        return [opener]
    opener = which("open")
    if opener:
        return [opener]
    return None

def parse_ssh_config_aliases(config_path):
    aliases = {}
    current_hosts = []
    try:
        lines = Path(config_path).read_text().splitlines()
    except OSError:
        return aliases
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if not parts:
            continue
        key = parts[0].lower()
        if key == "host":
            current_hosts = [p for p in parts[1:] if "*" not in p and "?" not in p]
        elif key == "hostname" and current_hosts and len(parts) >= 2:
            aliases.setdefault(parts[1], current_hosts[0])
    return aliases

def resolve_ssh_host(payload):
    explicit = (payload.get("ssh_host") or payload.get("ssh_to_me") or "").strip()
    if explicit:
        return explicit.split(None, 1)[1].strip() if explicit.startswith("ssh ") else explicit
    host = (payload.get("remote_machine_hostname") or payload.get("host") or "").strip()
    if not host:
        return ""
    return parse_ssh_config_aliases(Path.home() / ".ssh" / "config").get(host, host)

def handle_ping(payload):
    return {"status": "ok", "message": "pong", "bridge": "ssh-bridge"}

def handle_vscode_open(payload):
    code_cmd = choose_code_cmd()
    if not code_cmd:
        return {"status": "error", "message": "local machine does not have code or code-insiders in PATH"}
    path = (payload.get("path") or "").strip()
    ssh_host = resolve_ssh_host(payload)
    if not path:
        return {"status": "error", "message": "vscode.open request did not include a path"}
    if not ssh_host:
        return {"status": "error", "message": "vscode.open request did not include an SSH config host"}
    cmd = [code_cmd, "--remote", f"ssh-remote+{ssh_host}", path]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {
        "status": "ok",
        "type": "vscode.open",
        "code": code_cmd,
        "ssh_host": ssh_host,
        "path": path,
        "command": " ".join(shlex.quote(part) for part in cmd),
    }

def sanitize_cache_name(value):
    value = value.strip() or "unknown"
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)

def local_remote_copy_path(ssh_host, remote_path):
    remote = Path(remote_path)
    if not remote.is_absolute():
        raise ValueError("file.open path must be absolute")
    root = Path("/tmp") / f"remote_{sanitize_cache_name(ssh_host)}"
    return root / str(remote).lstrip("/")

def handle_file_open(payload):
    path = (payload.get("path") or "").strip()
    ssh_host = resolve_ssh_host(payload)
    if not path:
        return {"status": "error", "message": "file.open request did not include a path"}
    if not ssh_host:
        return {"status": "error", "message": "file.open request did not include an SSH config host"}
    try:
        local_path = local_remote_copy_path(ssh_host, path)
    except ValueError as exc:
        return {"status": "error", "message": str(exc)}
    local_path.parent.mkdir(parents=True, exist_ok=True)
    rsync = which("rsync")
    if not rsync:
        return {"status": "error", "message": "local machine does not have rsync in PATH"}
    rsync_cmd = [rsync, "-a", "--progress", f"{ssh_host}:{path}", str(local_path)]
    proc = subprocess.run(rsync_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return {"status": "error", "message": proc.stderr.decode("utf-8", "replace").strip() or "rsync failed"}
    opener = choose_opener()
    if not opener:
        return {"status": "error", "message": f"downloaded to {local_path}, but local machine has no opener (open/xdg-open)"}
    open_cmd = opener + [str(local_path)]
    subprocess.Popen(open_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {
        "status": "ok",
        "type": "file.open",
        "ssh_host": ssh_host,
        "path": path,
        "local_path": str(local_path),
        "rsync_command": " ".join(shlex.quote(part) for part in rsync_cmd),
        "command": " ".join(shlex.quote(part) for part in open_cmd),
    }

def handle_clipboard_write(payload):
    text = payload.get("text")
    if text is None:
        return {"status": "error", "message": "clipboard.write request did not include text"}
    writer = choose_clipboard_writer()
    if not writer:
        return {"status": "error", "message": "local machine has no clipboard writer (pbcopy/wl-copy/xclip/xsel)"}
    proc = subprocess.run(writer, input=text.encode("utf-8", "surrogateescape"), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return {"status": "error", "message": proc.stderr.decode("utf-8", "replace").strip() or "clipboard writer failed"}
    return {"status": "ok", "type": "clipboard.write", "bytes": len(text.encode("utf-8", "surrogateescape")), "command": " ".join(shlex.quote(part) for part in writer)}

HANDLERS = {
    "ping": handle_ping,
    "vscode.open": handle_vscode_open,
    "file.open": handle_file_open,
    "clipboard.write": handle_clipboard_write,
}

def normalize_payload(payload):
    if payload.get("ping") is True and "type" not in payload:
        payload["type"] = "ping"
    if "type" not in payload and "path" in payload:
        payload["type"] = "vscode.open"
    return payload

def handle_payload(payload):
    payload = normalize_payload(payload)
    request_type = payload.get("type")
    handler = HANDLERS.get(request_type)
    if not handler:
        return {"status": "error", "message": f"unknown ssh-bridge request type: {request_type}"}
    return handler(payload)

def serve():
    base_dir.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        socket_path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    socket_path.chmod(0o600)
    server.listen(32)
    pid_path.write_text(str(os.getpid()))

    def cleanup(*_):
        try:
            server.close()
        finally:
            for path in (socket_path, pid_path):
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    while True:
        conn, _ = server.accept()
        with conn:
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            try:
                payload = json.loads(data.decode("utf-8").strip())
                response = handle_payload(payload)
            except Exception as exc:
                response = {"status": "error", "message": str(exc)}
            try:
                conn.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))
            except BrokenPipeError:
                pass

def socket_responds():
    if not socket_path.exists():
        return False
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(str(socket_path))
        client.sendall(b'{"type":"ping"}\n')
        data = client.recv(65536)
        client.close()
        return b'"status": "ok"' in data or b'"status":"ok"' in data
    except OSError:
        return False

def start(quiet=False):
    base_dir.mkdir(parents=True, exist_ok=True)
    if socket_responds():
        if not quiet:
            print(f"ssh-bridge: running at {socket_path}")
        return 0
    if socket_path.exists():
        socket_path.unlink()
    log = log_path.open("ab")
    subprocess.Popen(
        ["/bin/bash", script_path, "bridge", "serve"],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    for _ in range(40):
        if socket_responds():
            if not quiet:
                print(f"ssh-bridge: started at {socket_path}")
            return 0
        time.sleep(0.05)
    print(f"ssh-bridge: failed to start; see {log_path}", file=sys.stderr)
    return 1

def stop():
    try:
        pid = int(pid_path.read_text().strip())
    except (OSError, ValueError):
        pid = None
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for path in (socket_path, pid_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    print("ssh-bridge: stopped")
    return 0

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["start", "serve", "stop", "status"])
parser.add_argument("--quiet", action="store_true")
args = parser.parse_args()

if args.action == "serve":
    serve()
elif args.action == "start":
    raise SystemExit(start(args.quiet))
elif args.action == "stop":
    raise SystemExit(stop())
elif args.action == "status":
    if socket_responds():
        print(f"ssh-bridge: running at {socket_path}")
        raise SystemExit(0)
    print("ssh-bridge: stopped")
    raise SystemExit(1)
PY
}

bridge_cmd() {
    local action="${1:-status}"
    [[ $# -gt 0 ]] && shift
    export SSH_BRIDGE_LOCAL_DIR="$LOCAL_BASE_DIR"
    export SSH_BRIDGE_LOCAL_SOCKET="$LOCAL_SOCKET"
    export SSH_BRIDGE_LOCAL_PID="$LOCAL_PID"
    export SSH_BRIDGE_LOCAL_LOG="$LOCAL_LOG"
    export SSH_BRIDGE_SCRIPT="${BASH_SOURCE[0]}"
    bridge_python "$action" "$@"
}

load_remote_context() {
    REMOTE_STATE_DIR="$(remote_state_dir)"
    REMOTE_SOCKET="${SSH_BRIDGE_SOCKET_REMOTE:-/tmp/ssh-bridge-${USER:-user}.sock}"
    [[ -z "${SSH_BRIDGE_SOCKET_REMOTE:-}" ]] && REMOTE_SOCKET="$(read_first_existing "$REMOTE_STATE_DIR/socket" || true)"
    [[ -n "${REMOTE_SOCKET:-}" ]] || REMOTE_SOCKET="/tmp/ssh-bridge-${USER:-user}.sock"
    REMOTE_TCP="${SSH_BRIDGE_TCP_REMOTE:-}"
    [[ -z "$REMOTE_TCP" ]] && REMOTE_TCP="$(read_first_existing "$REMOTE_STATE_DIR/tcp" || true)"
    REMOTE_MACHINE_HOSTNAME="$(remote_hostname)"
    REMOTE_SSH_HOST="${_SSH_BRIDGE_HOST:-${_SSH_TO_ME:-}}"
    [[ -z "$REMOTE_SSH_HOST" ]] && REMOTE_SSH_HOST="$(read_first_existing "$REMOTE_STATE_DIR/ssh_host" "$REMOTE_STATE_DIR/ssh_to_me" || true)"
    return 0
}

print_remote_bridge_help() {
    local request_name="${1:-request}"
    local reconnect_target="${REMOTE_SSH_HOST:-<ssh-config-host>}"
    cat >&2 <<EOF_HELP
Problem: SSH host '${reconnect_target}' is missing the local ssh-bridge for '${request_name}'.
Cause: the remote command is installed, but your Mac did not create the SSH bridge/tunnel when you connected.
Note: use the Host name from your LOCAL ~/.ssh/config, not the remote machine hostname '${REMOTE_MACHINE_HOSTNAME}'.

Solution: on your LOCAL Mac, add these lines to the matching Host block in ~/.ssh/config:

Host ${reconnect_target}
    PermitLocalCommand yes
    LocalCommand /Users/anhvth/dotfiles/mybins/ss-bridge local-command %n %r
    SetEnv _SSH_BRIDGE_HOST=%n
Then reconnect from your Mac with: ssh ${reconnect_target}

Note: curl | sh only installs remote client commands; it does not configure your Mac SSH bridge.
Remote install command: curl -fsSL https://raw.githubusercontent.com/anhvth/ssh-socket/refs/heads/main/install-vsc.sh | sh

Debug: ssh_config_host=${reconnect_target} remote_machine_hostname=${REMOTE_MACHINE_HOSTNAME} state_dir=${REMOTE_STATE_DIR} socket=${REMOTE_SOCKET} tcp=${REMOTE_TCP:-<unset>}
EOF_HELP
}

send_json() {
    local payload="$1" request_name="${2:-request}" debug="${3:-0}"
    load_remote_context
    (( debug )) && {
        printf 'ssh-bridge debug: request=%s\n' "$request_name" >&2
        printf 'ssh-bridge debug: payload=%s\n' "$payload" >&2
        printf 'ssh-bridge debug: state_dir=%s\n' "$REMOTE_STATE_DIR" >&2
        printf 'ssh-bridge debug: socket=%s\n' "$REMOTE_SOCKET" >&2
        printf 'ssh-bridge debug: tcp=%s\n' "${REMOTE_TCP:-<unset>}" >&2
        printf 'ssh-bridge debug: ssh_host=%s\n' "${REMOTE_SSH_HOST:-<unset>}" >&2
        printf 'ssh-bridge debug: remote_machine_hostname=%s\n' "$REMOTE_MACHINE_HOSTNAME" >&2
    }
    if [[ -z "$REMOTE_TCP" && ! -S "$REMOTE_SOCKET" ]]; then
        print_remote_bridge_help "$request_name"
        return 1
    fi

    local response status message
    response="$(
        SSH_BRIDGE_PAYLOAD="$payload" \
        SSH_BRIDGE_SOCKET="$REMOTE_SOCKET" \
        SSH_BRIDGE_TCP="$REMOTE_TCP" \
        python3 - <<'PY'
import json
import os
import socket
import sys

payload = os.environ["SSH_BRIDGE_PAYLOAD"]
sock_path = os.environ["SSH_BRIDGE_SOCKET"]
tcp_target = os.environ.get("SSH_BRIDGE_TCP") or ""
client = None
try:
    if tcp_target:
        host, port = tcp_target.rsplit(":", 1)
        client = socket.create_connection((host, int(port)), timeout=2)
    else:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(sock_path)
    client.sendall((payload + "\n").encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    data = client.recv(65536).decode("utf-8", "replace")
except OSError as exc:
    print(json.dumps({"status": "error", "message": f"ssh-bridge is not accepting connections ({exc.strerror or exc})"}))
    raise SystemExit(0)
finally:
    if client is not None:
        try:
            client.close()
        except Exception:
            pass
sys.stdout.write(data)
PY
    )"
    (( debug )) && printf 'ssh-bridge debug: response=%s\n' "$response" >&2
    status="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","error"))' 2>/dev/null || printf error)"
    if [[ "$status" != ok ]]; then
        message="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","bridge request failed"))' 2>/dev/null || printf 'bridge request failed')"
        echo "ssh-bridge: $message" >&2
        if [[ "$message" == *"ssh-bridge"* || "$message" == *"accepting connections"* || "$message" == *"Connection refused"* ]]; then
            print_remote_bridge_help "$request_name"
        fi
        return 1
    fi
    printf '%s\n' "$response"
}

json_escape_stdin() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

code_cmd() {
    local debug=0 target_raw="" arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; return 0 ;;
            --vvv) debug=1 ;;
            *)
                if [[ -z "$target_raw" ]]; then target_raw="$arg"; else echo "ss-code: unexpected argument: $arg" >&2; return 2; fi
                ;;
        esac
    done
    target_raw="${target_raw:-.}"
    local target
    target="$(resolve_path "$target_raw")"
    if ! is_remote_shell; then
        local code_cmd
        code_cmd="$(choose_code_cmd)" || { echo "ss-code: neither 'code' nor 'code-insiders' is available." >&2; return 127; }
        (( debug )) && printf 'ss-code debug: local path=%s code=%s\n' "$target" "$code_cmd" >&2
        exec "$code_cmd" "$target"
    fi
    load_remote_context
    local payload response
    payload="$(
        SSH_BRIDGE_TYPE="vscode.open" \
        SSH_BRIDGE_PATH="$target" \
        SSH_BRIDGE_SSH_HOST="${REMOTE_SSH_HOST:-}" \
        SSH_BRIDGE_REMOTE_HOST="$REMOTE_MACHINE_HOSTNAME" \
        SSH_BRIDGE_USER="${USER:-}" \
        python3 - <<'PY'
import json, os
print(json.dumps({
    "type": os.environ["SSH_BRIDGE_TYPE"],
    "path": os.environ["SSH_BRIDGE_PATH"],
    "ssh_host": os.environ.get("SSH_BRIDGE_SSH_HOST") or "",
    "remote_machine_hostname": os.environ.get("SSH_BRIDGE_REMOTE_HOST") or "",
    "user": os.environ.get("SSH_BRIDGE_USER") or "",
}))
PY
    )"
    response="$(send_json "$payload" "vscode.open" "$debug")" || return 1
    (( debug )) && printf 'ss-code debug: bridge response=%s\n' "$response" >&2
}

open_cmd() {
    local debug=0 target_raw="" arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) echo 'Usage: ss-open [path] [--vvv]'; return 0 ;;
            --vvv) debug=1 ;;
            *)
                if [[ -z "$target_raw" ]]; then target_raw="$arg"; else echo "ss-open: unexpected argument: $arg" >&2; return 2; fi
                ;;
        esac
    done
    target_raw="${target_raw:-.}"
    local target
    target="$(resolve_path "$target_raw")"

    if ! is_remote_shell; then
        if [[ -x /usr/bin/open ]]; then
            exec /usr/bin/open "$target"
        elif command -v xdg-open >/dev/null 2>&1; then
            exec xdg-open "$target"
        else
            echo "ss-open: no opener found (open/xdg-open)." >&2
            return 127
        fi
    fi

    if [[ ! -e "$target" ]]; then
        echo "ss-open: remote path not found: $target" >&2
        return 1
    fi
    if [[ -d "$target" ]]; then
        echo "ss-open: directories are not supported yet: $target" >&2
        return 1
    fi

    load_remote_context
    local payload response
    payload="$(
        SSH_BRIDGE_TYPE="file.open" \
        SSH_BRIDGE_PATH="$target" \
        SSH_BRIDGE_SSH_HOST="${REMOTE_SSH_HOST:-}" \
        SSH_BRIDGE_REMOTE_HOST="$REMOTE_MACHINE_HOSTNAME" \
        SSH_BRIDGE_USER="${USER:-}" \
        python3 - <<'PY'
import json, os
print(json.dumps({
    "type": os.environ["SSH_BRIDGE_TYPE"],
    "path": os.environ["SSH_BRIDGE_PATH"],
    "ssh_host": os.environ.get("SSH_BRIDGE_SSH_HOST") or "",
    "remote_machine_hostname": os.environ.get("SSH_BRIDGE_REMOTE_HOST") or "",
    "user": os.environ.get("SSH_BRIDGE_USER") or "",
}))
PY
    )"
    response="$(send_json "$payload" "file.open" "$debug")" || return 1
    (( debug )) && printf 'ss-open debug: bridge response=%s\n' "$response" >&2
}

copy_local_fallback() {
    local tmp="$1"
    copy_osc52() {
        command -v base64 >/dev/null 2>&1 || return 1
        if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
            if tmux load-buffer -w - < "$tmp" 2>/dev/null; then return 0; fi
        fi
        local target=""
        if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
            target="$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)"
        fi
        [[ -z "$target" && -w /dev/tty ]] && target="/dev/tty"
        [[ -n "$target" && -w "$target" ]] || return 1
        local encoded
        encoded="$(base64 < "$tmp" | tr -d '\r\n')"
        printf '\033]52;c;%s\a' "$encoded" > "$target"
    }
    case "${OSTYPE:-}" in
        darwin*) command -v pbcopy >/dev/null 2>&1 && pbcopy < "$tmp" && return 0 ;;
        cygwin*) [[ -w /dev/clipboard ]] && cat "$tmp" > /dev/clipboard && return 0 ;;
    esac
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1 && wl-copy < "$tmp"; then return 0; fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1 && xclip -in -selection clipboard < "$tmp"; then return 0; fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1 && xsel --clipboard --input < "$tmp"; then return 0; fi
    copy_osc52
}

copy_cmd() {
    local debug=0 arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) echo 'Usage: ss-copy [--vvv] < stdin'; return 0 ;;
            --vvv) debug=1 ;;
            *) echo "ss-copy: unexpected argument: $arg" >&2; return 2 ;;
        esac
    done
    local tmp select_file response payload text_json
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp"
    if is_remote_shell; then
        load_remote_context
        select_file="$REMOTE_STATE_DIR/tmux_copy_text_select"
    else
        select_file="${SSH_BRIDGE_LOCAL_SELECTION_FILE:-${LOCAL_BASE_DIR}/tmux_copy_text_select}"
    fi
    mkdir -p "$(dirname "$select_file")" 2>/dev/null || true
    if cp "$tmp" "$select_file" 2>/dev/null; then chmod 600 "$select_file" 2>/dev/null || true; fi

    if is_remote_shell; then
        text_json="$(json_escape_stdin < "$tmp")"
        payload="$(
            SSH_BRIDGE_TEXT_JSON="$text_json" \
            SSH_BRIDGE_SSH_HOST="${REMOTE_SSH_HOST:-}" \
            SSH_BRIDGE_REMOTE_HOST="$REMOTE_MACHINE_HOSTNAME" \
            SSH_BRIDGE_USER="${USER:-}" \
            python3 - <<'PY'
import json, os
print(json.dumps({
    "type": "clipboard.write",
    "text": json.loads(os.environ["SSH_BRIDGE_TEXT_JSON"]),
    "ssh_host": os.environ.get("SSH_BRIDGE_SSH_HOST") or "",
    "remote_machine_hostname": os.environ.get("SSH_BRIDGE_REMOTE_HOST") or "",
    "user": os.environ.get("SSH_BRIDGE_USER") or "",
}, ensure_ascii=False))
PY
        )"
        if response="$(send_json "$payload" "clipboard.write" "$debug")"; then
            (( debug )) && printf 'copy debug: bridge response=%s\n' "$response" >&2
            return 0
        fi
        (( debug )) && echo 'ss-copy debug: bridge failed; trying local/OSC52 fallback' >&2
    fi

    if copy_local_fallback "$tmp"; then
        return 0
    fi
    printf 'ss-copy: no clipboard target reachable; selection saved to %s\n' "$select_file" >&2
    return 0
}

send_cmd() {
    local request_type="${1:-}"
    [[ -n "$request_type" ]] || { echo 'Usage: ssh-bridge send <request-type> [json-fields]' >&2; return 2; }
    shift || true
    local fields="${1:-{}}"
    local payload
    payload="$(SSH_BRIDGE_TYPE="$request_type" SSH_BRIDGE_FIELDS="$fields" python3 - <<'PY'
import json, os
payload = json.loads(os.environ.get("SSH_BRIDGE_FIELDS") or "{}")
payload["type"] = os.environ["SSH_BRIDGE_TYPE"]
print(json.dumps(payload, ensure_ascii=False))
PY
    )"
    send_json "$payload" "$request_type" 1 >/dev/null
}

health_header() {
    printf '\n%s%s%s\n' "$HEALTH_BOLD" "$1" "$HEALTH_RESET"
    printf '%s\n' "------------------------------"
}

health_init_color() {
    HEALTH_RESET=""
    HEALTH_BOLD=""
    HEALTH_GREEN=""
    HEALTH_YELLOW=""
    HEALTH_RED=""
    HEALTH_DIM=""
    if [[ "${SS_HEALTH_COLOR:-auto}" == "never" ]]; then
        return 0
    fi
    if [[ "${SS_HEALTH_COLOR:-auto}" == "auto" && -n "${NO_COLOR:-}" ]]; then
        return 0
    fi
    if [[ "${SS_HEALTH_COLOR:-auto}" != "always" && ! -t 1 ]]; then
        return 0
    fi
    HEALTH_RESET="$(printf '\033[0m')"
    HEALTH_BOLD="$(printf '\033[1m')"
    HEALTH_GREEN="$(printf '\033[32m')"
    HEALTH_YELLOW="$(printf '\033[33m')"
    HEALTH_RED="$(printf '\033[31m')"
    HEALTH_DIM="$(printf '\033[2m')"
}

health_line() {
    local status="$1" name="$2" detail="${3:-}"
    case "$status" in
        pass) printf '  %s[PASS]%s %-22s %s%s%s\n' "$HEALTH_GREEN" "$HEALTH_RESET" "$name" "$HEALTH_DIM" "$detail" "$HEALTH_RESET" ;;
        warn) printf '  %s[WARN]%s %-22s %s%s%s\n' "$HEALTH_YELLOW" "$HEALTH_RESET" "$name" "$HEALTH_DIM" "$detail" "$HEALTH_RESET"; HEALTH_WARNS=$((HEALTH_WARNS + 1)) ;;
        fail) printf '  %s[FAIL]%s %-22s %s%s%s\n' "$HEALTH_RED" "$HEALTH_RESET" "$name" "$HEALTH_DIM" "$detail" "$HEALTH_RESET"; HEALTH_FAILS=$((HEALTH_FAILS + 1)) ;;
    esac
}

health_pass() {
    health_line pass "$1" "${2:-}"
}

health_warn() {
    health_line warn "$1" "${2:-}"
}

health_fail() {
    health_line fail "$1" "${2:-}"
}

health_verdict() {
    local label="$1"
    printf '\n%sSummary%s\n' "$HEALTH_BOLD" "$HEALTH_RESET"
    printf '%s\n' "------------------------------"
    if (( HEALTH_FAILS == 0 )); then
        if (( HEALTH_WARNS == 0 )); then
            printf '  RESULT: %sGREEN%s - %s is ready\n' "$HEALTH_GREEN" "$HEALTH_RESET" "$label"
        else
            printf '  RESULT: %sGREEN%s - %s is ready (%d warning(s))\n' "$HEALTH_GREEN" "$HEALTH_RESET" "$label" "$HEALTH_WARNS"
        fi
        return 0
    fi
    printf '  RESULT: %sRED%s - %s has %d blocking issue(s), %d warning(s)\n' "$HEALTH_RED" "$HEALTH_RESET" "$label" "$HEALTH_FAILS" "$HEALTH_WARNS"
    return 1
}

health_have_cmd() {
    local name="$1" path
    if path="$(command -v "$name" 2>/dev/null)"; then
        health_pass "$name" "$path"
    else
        health_fail "$name" "not found in PATH"
    fi
}

health_have_file() {
    local path="$1"
    if [[ -x "$path" ]]; then
        health_pass "$(basename "$path")" "$path"
    else
        health_fail "$(basename "$path")" "missing or not executable: $path"
    fi
}

health_old_absent() {
    local path="$1"
    if [[ -e "$path" ]]; then
        health_fail "legacy $(basename "$path")" "still exists: $path"
    else
        health_pass "legacy $(basename "$path")" "absent: $path"
    fi
}

health_remote_cmd() {
    HEALTH_FAILS=0
    HEALTH_WARNS=0
    health_init_color
    local install_dir="${HOME}/.local/bin" state_dir tcp ssh_host response ping_err
    printf '%sss-health remote%s\n' "$HEALTH_BOLD" "$HEALTH_RESET"
    printf '%shost=%s user=%s install_dir=%s%s\n' "$HEALTH_DIM" "$(remote_hostname)" "${USER:-unknown}" "$install_dir" "$HEALTH_RESET"

    health_header "Runtime"
    health_have_cmd python3

    health_header "Installed clients"
    for name in ss-bridge ss-code ss-open ss-open-remote ss-copy ss-pbcopy ss-health ss-setup; do
        health_have_file "$install_dir/$name"
    done

    health_header "Legacy cleanup"
    for old_name in ssh-bridge vsc open open-remote copy pbcopy vsc-bridge vsc-ssh-local-command; do
        health_old_absent "$install_dir/$old_name"
        if [[ -d "$HOME/dotfiles/mybins" ]]; then
            health_old_absent "$HOME/dotfiles/mybins/$old_name"
        fi
    done

    health_header "Bridge state"
    state_dir="$(remote_state_dir)"
    if [[ -d "$state_dir" ]]; then health_pass "state dir" "$state_dir"; else health_fail "state dir" "missing: $state_dir"; fi
    tcp="$(read_first_existing "$state_dir/tcp" || true)"
    ssh_host="$(read_first_existing "$state_dir/ssh_host" "$state_dir/ssh_to_me" || true)"
    if [[ -n "$tcp" ]]; then health_pass "tcp target" "$tcp"; else health_fail "tcp target" "missing"; fi
    if [[ -n "$ssh_host" ]]; then health_pass "ssh host" "$ssh_host"; else health_fail "ssh host" "missing"; fi

    health_header "Connectivity"
    ping_err="${state_dir}/ss-health-ping.err"
    if response="$(send_json '{"type":"ping"}' "health.ping" 0 2>"$ping_err")"; then
        health_pass "bridge ping" "$response"
    else
        health_fail "bridge ping" "$(cat "$ping_err" 2>/dev/null || true)"
    fi

    health_header "Tmux copy path"
    if command -v tmux >/dev/null 2>&1; then
        local tmux_keys stale_keys copy_test select_file
        tmux_keys="$(tmux list-keys -T copy-mode-vi 2>/dev/null | grep -E 'copy-pipe.*(y|Enter|MouseDragEnd1Pane)|DoubleClick1Pane|TripleClick1Pane' || true)"
        stale_keys="$(printf '%s\n' "$tmux_keys" | grep -E 'dotfiles/(utils|mybins)|ssh-tmux-copy|/tmp/tmux_copy_text_select' || true)"
        if printf '%s\n' "$tmux_keys" | grep -q "$install_dir/ss-copy"; then
            health_pass "tmux binding" "$install_dir/ss-copy"
        else
            health_fail "tmux binding" "copy-mode keys do not use $install_dir/ss-copy"
        fi
        if [[ -z "$stale_keys" ]]; then
            health_pass "stale tmux binding" "none"
        else
            health_fail "stale tmux binding" "$(printf '%s' "$stale_keys" | tr '\n' ';' | cut -c1-220)"
        fi
        select_file="$state_dir/tmux_copy_text_select"
        copy_test="ss-health-copy-$(date +%s)-$$"
        if printf '%s' "$copy_test" | "$install_dir/ss-copy" >/dev/null 2>"$state_dir/ss-copy-test.err" &&
            [[ -s "$select_file" ]] &&
            grep -q "$copy_test" "$select_file"; then
            health_pass "ss-copy write" "$select_file"
        else
            health_fail "ss-copy write" "$(cat "$state_dir/ss-copy-test.err" 2>/dev/null || printf 'selection file not updated: %s' "$select_file")"
        fi
    else
        health_warn "tmux" "not installed; skipping tmux binding check"
    fi

    health_header "PATH hygiene"
    local resolved_vsc resolved_copy
    resolved_vsc="$(command -v vsc 2>/dev/null || true)"
    resolved_copy="$(command -v copy 2>/dev/null || true)"
    if [[ -z "$resolved_vsc" ]]; then
        health_pass "vsc command" "not present"
    else
        health_fail "vsc command" "legacy command still resolves to $resolved_vsc"
    fi
    if [[ -z "$resolved_copy" ]]; then
        health_pass "copy command" "not present"
    else
        health_fail "copy command" "legacy command still resolves to $resolved_copy"
    fi
    health_verdict "remote bridge"
}

health_local_cmd() {
    local host="${1:-}" code_cmd opener clipboard_writer dotfiles_bin="$HOME/dotfiles/mybins"
    HEALTH_FAILS=0
    HEALTH_WARNS=0
    health_init_color
    printf '%sss-health local%s\n' "$HEALTH_BOLD" "$HEALTH_RESET"
    printf '%shost=%s user=%s socket=%s%s\n' "$HEALTH_DIM" "$(hostname 2>/dev/null || printf unknown)" "${USER:-unknown}" "$LOCAL_SOCKET" "$HEALTH_RESET"

    health_header "Runtime"
    health_have_cmd python3
    health_have_cmd ssh
    health_have_cmd rsync

    health_header "Local app integrations"
    if code_cmd="$(choose_code_cmd 2>/dev/null)"; then health_pass "VS Code CLI" "$code_cmd"; else health_fail "VS Code CLI" "code or code-insiders not found"; fi
    if [[ -x /usr/bin/open ]]; then
        opener="/usr/bin/open"
    elif command -v xdg-open >/dev/null 2>&1; then
        opener="$(command -v xdg-open)"
    else
        opener=""
    fi
    if [[ -n "$opener" ]]; then health_pass "file opener" "$opener"; else health_fail "file opener" "open or xdg-open not found"; fi
    if command -v pbcopy >/dev/null 2>&1; then
        clipboard_writer="$(command -v pbcopy)"
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
        clipboard_writer="$(command -v wl-copy)"
    elif command -v xclip >/dev/null 2>&1; then
        clipboard_writer="$(command -v xclip)"
    elif command -v xsel >/dev/null 2>&1; then
        clipboard_writer="$(command -v xsel)"
    else
        clipboard_writer=""
    fi
    if [[ -n "$clipboard_writer" ]]; then health_pass "clipboard writer" "$clipboard_writer"; else health_fail "clipboard writer" "pbcopy/wl-copy/xclip/xsel not found"; fi

    health_header "Local clients"
    for name in ss-bridge ss-code ss-open ss-open-remote ss-copy ss-pbcopy ss-health ss-setup; do
        if [[ -d "$dotfiles_bin" ]]; then
            health_have_file "$dotfiles_bin/$name"
        else
            health_have_cmd "$name"
        fi
    done

    health_header "Local daemon"
    if bridge_cmd start --quiet >/dev/null 2>&1 && bridge_cmd status >/dev/null 2>&1; then
        health_pass "daemon" "running at $LOCAL_SOCKET"
    else
        health_fail "daemon" "failed to start; see $LOCAL_LOG"
    fi

    if [[ -n "$host" ]]; then
        local remote_color="never"
        [[ -n "$HEALTH_GREEN" ]] && remote_color="always"
        health_header "Remote host: $host"

        # Check SSH config integration
        local ssh_g_output permit_local_cmd local_cmd
        ssh_g_output="$(ssh -G "$host" 2>/dev/null || true)"
        permit_local_cmd="$(printf '%s\n' "$ssh_g_output" | awk '$1 == "permitlocalcommand" { print $2 }' || true)"
        local_cmd="$(printf '%s\n' "$ssh_g_output" | awk '$1 == "localcommand" { $1=""; print $0 }' | sed 's/^ //' || true)"

        local config_ok=1
        if [[ "$permit_local_cmd" != "yes" ]]; then
            config_ok=0
            health_fail "ssh PermitLocalCommand" "set to '$permit_local_cmd', must be 'yes'"
        else
            health_pass "ssh PermitLocalCommand" "yes"
        fi

        if [[ -z "$local_cmd" ]]; then
            config_ok=0
            health_fail "ssh LocalCommand" "missing or empty"
        elif [[ "$local_cmd" != *"ss-bridge local-command"* && "$local_cmd" != *"ssh-bridge.sh local-command"* ]]; then
            config_ok=0
            health_fail "ssh LocalCommand" "does not invoke local-command (found: '$local_cmd')"
        else
            health_pass "ssh LocalCommand" "$local_cmd"
        fi

        if (( config_ok )); then
            health_pass "bootstrap" "install/update requested via LocalCommand path"
            local_command_cmd "$host" || true
        else
            health_fail "bootstrap" "skipped because LocalCommand is not configured in ~/.ssh/config"
        fi

        if ssh \
            -o PermitLocalCommand=no \
            -o LocalCommand=true \
            -o ClearAllForwardings=yes \
            -o ControlMaster=no \
            -o ControlPath=none \
            -o BatchMode=yes \
            "$host" \
            "SS_HEALTH_COLOR=$remote_color \$HOME/.local/bin/ss-health --remote"; then
            health_pass "remote health" "$host"
        else
            health_fail "remote health" "$host failed; run ssh $host and retry"
        fi
    fi
    health_verdict "local bridge"
}

health_cmd() {
    case "${1:-}" in
        -h|--help)
            echo 'Usage: ss-health [ssh-config-host]'
            echo '       ss-health --remote'
            return 0
            ;;
        --remote)
            health_remote_cmd
            ;;
        *)
            if is_remote_shell && [[ $# -eq 0 ]]; then
                health_remote_cmd
            else
                health_local_cmd "${1:-}"
            fi
            ;;
    esac
}

setup_cmd() {
    local host="${1:-}"
    if [[ -z "$host" || "$host" == "-h" || "$host" == "--help" ]]; then
        echo 'Usage: ss-setup <ssh-config-host>'
        echo 'Starts local daemon, installs/updates remote ss-* clients, creates tunnel state, then runs ss-health.'
        return 2
    fi
    if is_remote_shell; then
        echo "ss-setup: run this on your local Mac, not inside the remote SSH session." >&2
        return 2
    fi
    local_command_cmd "$host"
    health_local_cmd "$host"
}

install_remote_script() {
    local ssh_target="$1" ssh_host="$2"
    {
        cat <<'REMOTE_SETUP_PREFIX'
set -eu
ssh_host="$1"
remote_tcp_port="$2"
install_dir="$HOME/.local/bin"
dotfiles_bin="$HOME/dotfiles/mybins"
remote_host="$(hostname 2>/dev/null || printf unknown)"
state_root="/tmp/ssh-bridge/${USER:-user}/${remote_host}"
mkdir -p "$install_dir" "$state_root"
printf "127.0.0.1:%s\n" "$remote_tcp_port" > "$state_root/tcp"
printf '%s\n' "$ssh_host" > "$state_root/ssh_host"
printf '%s\n' "$ssh_host" > "$state_root/ssh_to_me"
tmp="${TMPDIR:-/tmp}/ssh-bridge.$$"
base64 -d > "$tmp" <<'SSH_BRIDGE_CLIENT_B64'
REMOTE_SETUP_PREFIX
        base64 < "${BASH_SOURCE[0]}"
        cat <<'REMOTE_SETUP_SUFFIX'
SSH_BRIDGE_CLIENT_B64
chmod +x "$tmp"
for old_name in ssh-bridge vsc open open-remote copy pbcopy vsc-bridge vsc-ssh-local-command; do
    rm -f "$install_dir/$old_name"
    if [ -d "$dotfiles_bin" ]; then
        rm -f "$dotfiles_bin/$old_name"
    fi
done
cp "$tmp" "$install_dir/ss-bridge"
for name in ss-code ss-open ss-open-remote ss-copy ss-pbcopy ss-health ss-setup; do
    cp "$tmp" "$install_dir/$name"
    chmod +x "$install_dir/$name"
done
chmod +x "$install_dir/ss-bridge"
rm -f "$tmp"
if command -v tmux >/dev/null 2>&1; then
    copy_cmd="$install_dir/ss-copy"
    tmux bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -n DoubleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-word \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -n TripleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-line \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi TripleClick1Pane select-pane \; send-keys -X select-line \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ssh-bridge: installed clients, but python3 is required for remote requests" >&2
fi
REMOTE_SETUP_SUFFIX
    } | ssh \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ClearAllForwardings=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        "$ssh_target" \
        sh -s -- "$ssh_host" "$REMOTE_PORT" >>"$LOCAL_LOG" 2>&1 || true
}

remote_ping() {
    local ssh_target="$1"
    ssh \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ClearAllForwardings=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        "$ssh_target" \
        python3 - "$REMOTE_PORT" >>"$LOCAL_LOG" 2>&1 <<'PY'
import json
import socket
import sys
port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=1) as client:
    client.sendall(b'{"type":"ping"}\n')
    client.shutdown(socket.SHUT_WR)
    data = client.recv(65536).decode("utf-8", "replace")
response = json.loads(data)
raise SystemExit(0 if response.get("status") == "ok" else 1)
PY
}

start_reverse_tunnel() {
    local ssh_target="$1"
    local existing_tunnel_pids
    existing_tunnel_pids="$(
        ps -axo pid,command |
            awk -v port="$REMOTE_PORT" -v target="$ssh_target" '
                $0 ~ "ssh .*127\\.0\\.0\\.1:" port ":" && $0 ~ target && $0 !~ /awk/ { print $1 }
            '
    )"
    if [[ -n "$existing_tunnel_pids" ]]; then
        kill $existing_tunnel_pids 2>/dev/null || true
        sleep 0.2
    fi
    ssh \
        -fN \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o ExitOnForwardFailure=yes \
        -o BatchMode=yes \
        -R "127.0.0.1:${REMOTE_PORT}:${LOCAL_SOCKET}" \
        "$ssh_target" >>"$LOCAL_LOG" 2>&1 || true
}

local_command_cmd() {
    local ssh_host="${1:-}" ssh_user="${2:-}"
    [[ -n "$ssh_host" ]] || return 0
    mkdir -p "$LOCAL_BASE_DIR"
    bridge_cmd start --quiet || true
    local ssh_target="$ssh_host"
    [[ -n "$ssh_user" ]] && ssh_target="${ssh_user}@${ssh_host}"
    install_remote_script "$ssh_target" "$ssh_host"
    if remote_ping "$ssh_target"; then
        return 0
    fi
    start_reverse_tunnel "$ssh_target"
}

case "$cmd" in
    bridge) bridge_cmd "$@" ;;
    local-command) local_command_cmd "$@" ;;
    send) send_cmd "$@" ;;
    code) code_cmd "$@" ;;
    open) open_cmd "$@" ;;
    copy) copy_cmd "$@" ;;
    health) health_cmd "$@" ;;
    setup) setup_cmd "$@" ;;
    help|-h|--help) usage ;;
    *) echo "ssh-bridge: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
