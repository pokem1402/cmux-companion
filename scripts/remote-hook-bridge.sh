#!/bin/sh
# cmux-companion-managed-remote-hook v3
#
# Telemetry-only bridge for agent hooks running inside a `cmux ssh` shell.
# It deliberately uses the remote `cmux` relay CLI. It never opens, copies, or
# forwards the local Mac's Unix socket. CMUX_SOCKET_PATH, when present, must be
# a loopback TCP endpoint created by cmux's authenticated reverse relay.

set -eu

source_name=""
event_name=""
heartbeat=0

usage() {
    cat <<'EOF'
Usage: remote-hook-bridge.sh [--source <agent>] [--event <HookEventName>] [--heartbeat]

Reads one agent hook JSON object from stdin and forwards telemetry through the
authenticated relay established by `cmux ssh`. Delivery is ordered for normal
sequential hooks and bounded to two short foreground attempts by default.

Options:
  --source <agent>          Agent source, such as codex or claude
  --event <name>            Override/inject the cmux hook event name
  --heartbeat               Emit a remote liveness heartbeat
  -h, --help                Show this help

Environment:
  CMUX_COMPANION_HOOK_RPC_TIMEOUT_MS  Per-attempt timeout, 100...2000 (default 900)
  CMUX_COMPANION_HOOK_RPC_ATTEMPTS    Attempts, 1...3 (default 2)
  CMUX_COMPANION_HOOK_DEBUG           Set to 1 for stderr diagnostics
EOF
}

warn() {
    if [ "${CMUX_COMPANION_HOOK_DEBUG:-0}" = "1" ]; then
        printf '%s\n' "cmux-companion remote hook: $*" >&2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { warn "--source requires a value"; exit 0; }
            source_name=$2
            shift 2
            ;;
        --event)
            [ "$#" -ge 2 ] || { warn "--event requires a value"; exit 0; }
            event_name=$2
            shift 2
            ;;
        --heartbeat)
            heartbeat=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            warn "unknown argument: $1"
            exit 0
            ;;
    esac
done

workspace_id=${CMUX_WORKSPACE_ID:-${CMUX_TAB_ID:-}}
surface_id=${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}

# Agent hooks must never be made fatal by missing companion telemetry context.
if [ -z "$workspace_id" ] || [ -z "$surface_id" ]; then
    warn "missing CMUX_WORKSPACE_ID or CMUX_SURFACE_ID; run the agent through cmux ssh"
    exit 0
fi

# A normal cmux ssh bootstrap exports 127.0.0.1:<relay-port>. Reject Unix
# paths and non-loopback endpoints so this helper cannot expose the Mac app
# socket or send hook contents to an arbitrary network endpoint.
relay_verified=0
if [ -n "${CMUX_SOCKET_PATH:-}" ]; then
    case "$CMUX_SOCKET_PATH" in
        127.0.0.1:*|localhost:*|'[::1]':*) relay_verified=1 ;;
        *)
            warn "refusing non-loopback CMUX_SOCKET_PATH"
            exit 0
            ;;
    esac
elif [ -f "${HOME}/.cmux/socket_addr" ]; then
    IFS= read -r discovered_socket < "${HOME}/.cmux/socket_addr" || discovered_socket=""
    case "$discovered_socket" in
        127.0.0.1:*|localhost:*|'[::1]':*) relay_verified=1 ;;
        *)
            warn "refusing non-loopback ~/.cmux/socket_addr"
            exit 0
            ;;
    esac
fi
if [ "$relay_verified" -ne 1 ]; then
    warn "no authenticated cmux ssh loopback relay was discovered"
    exit 0
fi

cmux_cli=""
if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "$CMUX_BUNDLED_CLI_PATH" ]; then
    cmux_cli=$CMUX_BUNDLED_CLI_PATH
elif command -v cmux >/dev/null 2>&1; then
    cmux_cli=$(command -v cmux)
fi
if [ -z "$cmux_cli" ]; then
    warn "remote cmux relay CLI not found"
    exit 0
fi

# The bridge uses Python for lossless JSON encoding and a portable subprocess
# timeout. Never select Python 2: it would silently drop all hook telemetry.
python_cli=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        candidate_path=$(command -v "$candidate")
        if "$candidate_path" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
            >/dev/null 2>&1; then
            python_cli=$candidate_path
            break
        fi
    fi
done
if [ -z "$python_cli" ]; then
    warn "Python 3.8 or newer is required to encode and deliver hook telemetry"
    exit 0
fi

remote_host=${HOSTNAME:-}
if [ -z "$remote_host" ]; then
    remote_host=$(hostname 2>/dev/null || printf '%s' unknown)
fi

CMUX_COMPANION_REMOTE_SOURCE=$source_name
CMUX_COMPANION_REMOTE_EVENT=$event_name
CMUX_COMPANION_REMOTE_HEARTBEAT=$heartbeat
CMUX_COMPANION_REMOTE_HOST=$remote_host
CMUX_COMPANION_REMOTE_WORKSPACE=$workspace_id
CMUX_COMPANION_REMOTE_SURFACE=$surface_id
CMUX_COMPANION_REMOTE_CMUX_CLI=$cmux_cli
export CMUX_COMPANION_REMOTE_SOURCE CMUX_COMPANION_REMOTE_EVENT
export CMUX_COMPANION_REMOTE_HEARTBEAT CMUX_COMPANION_REMOTE_HOST
export CMUX_COMPANION_REMOTE_WORKSPACE CMUX_COMPANION_REMOTE_SURFACE
export CMUX_COMPANION_REMOTE_CMUX_CLI

"$python_cli" -c '
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import uuid

MAX_STDIN_BYTES = 512 * 1024
MAX_PROMPT_CHARS = 64 * 1024
STATE_LOG_LIMIT = 256 * 1024


def bounded_int(name, default, minimum, maximum):
    try:
        value = int(os.environ.get(name, default))
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def debug(message):
    if os.environ.get("CMUX_COMPANION_HOOK_DEBUG") == "1":
        print("cmux-companion remote hook: %s" % message, file=sys.stderr)


def record_failure(reason, hook_name="unknown"):
    """Persist only operational metadata; never write prompts/tool input."""
    try:
        state_home = os.environ.get("XDG_STATE_HOME")
        if not state_home:
            state_home = os.path.join(os.path.expanduser("~"), ".local", "state")
        state_dir = os.path.join(state_home, "cmux-companion")
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        try:
            os.chmod(state_dir, 0o700)
        except OSError:
            pass
        log_path = os.path.join(state_dir, "remote-hook-errors.log")
        if os.path.exists(log_path) and os.path.getsize(log_path) > STATE_LOG_LIMIT:
            try:
                os.replace(log_path, log_path + ".1")
            except OSError:
                pass
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        safe_reason = str(reason).replace("\n", " ")[:240]
        line = "%s event=%s surface=%s reason=%s\n" % (
            timestamp,
            hook_name,
            os.environ.get("CMUX_COMPANION_REMOTE_SURFACE", "unknown"),
            safe_reason,
        )
        descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(descriptor, line.encode("utf-8", errors="replace"))
        finally:
            os.close(descriptor)
        try:
            os.chmod(log_path, 0o600)
        except OSError:
            pass
    except Exception:
        pass
    debug("delivery failure: %s" % reason)


def limited_identifier(value, fallback):
    text = str(value or fallback)
    if len(text) <= 512:
        return text
    digest = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
    return "%s:%s" % (text[:384], digest)


raw = sys.stdin.buffer.read(MAX_STDIN_BYTES + 1)
if len(raw) > MAX_STDIN_BYTES:
    record_failure("hook JSON exceeded 512 KiB and was not forwarded")
    raise SystemExit(0)
try:
    decoded = json.loads(raw.decode("utf-8")) if raw.strip() else {}
except Exception as error:
    record_failure("invalid hook JSON: %s" % type(error).__name__)
    raise SystemExit(0)

if isinstance(decoded, dict) and isinstance(decoded.get("event"), dict):
    native = dict(decoded["event"])
elif isinstance(decoded, dict):
    native = dict(decoded)
else:
    record_failure("hook JSON root was not an object")
    raise SystemExit(0)

source = (
    os.environ.get("CMUX_COMPANION_REMOTE_SOURCE")
    or native.get("_source")
    or native.get("source")
    or native.get("agent")
    or "remote"
)
requested_name = (
    os.environ.get("CMUX_COMPANION_REMOTE_EVENT")
    or native.get("hook_event_name")
    or native.get("hookEventName")
    or native.get("event_name")
    or native.get("event")
)
requested_text = requested_name if isinstance(requested_name, str) else str(requested_name or "")

known = {
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
    "PostToolUse", "PreCompact", "PostCompact", "PermissionRequest",
    "AskUserQuestion", "ExitPlanMode", "TodoWrite", "Stop",
    "SubagentStart", "SubagentStop", "Notification",
}
aliases = {
    "session_start": "SessionStart", "session_end": "SessionEnd",
    "user_prompt_submit": "UserPromptSubmit", "prompt_submit": "UserPromptSubmit",
    "pre_tool_use": "PreToolUse", "post_tool_use": "PostToolUse",
    "pre_compact": "PreCompact", "post_compact": "PostCompact",
    "permission_request": "PermissionRequest", "ask_user_question": "AskUserQuestion",
    "exit_plan_mode": "ExitPlanMode", "todo_write": "TodoWrite",
    "subagent_start": "SubagentStart", "subagent_stop": "SubagentStop",
    "stop": "Stop", "notification": "Notification",
}
if os.environ.get("CMUX_COMPANION_REMOTE_HEARTBEAT") == "1":
    original_hook_name = "Heartbeat"
    wire_hook_name = "SessionStart"
elif requested_text in known:
    original_hook_name = requested_text
    wire_hook_name = requested_text
else:
    normalized = aliases.get(requested_text.lower())
    if normalized is None:
        record_failure("missing or unsupported hook event", requested_text or "unknown")
        raise SystemExit(0)
    original_hook_name = normalized
    wire_hook_name = normalized

# Permission/question/plan hooks cannot be answered by this telemetry-only
# bridge. Sending them as their native kind would create an orphaned actionable
# Feed card. Notification is non-actionable while still mapping to `waiting`.
actionable = {"PermissionRequest", "AskUserQuestion", "ExitPlanMode"}
is_actionable_telemetry = original_hook_name in actionable
if is_actionable_telemetry:
    wire_hook_name = "Notification"

workspace = os.environ["CMUX_COMPANION_REMOTE_WORKSPACE"]
surface = os.environ["CMUX_COMPANION_REMOTE_SURFACE"]
host = os.environ.get("CMUX_COMPANION_REMOTE_HOST") or socket.gethostname()
now = datetime.datetime.now(datetime.timezone.utc)
apple_epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
received_at = (now - apple_epoch).total_seconds()
sequence = time.monotonic_ns()
try:
    with open("/proc/sys/kernel/random/boot_id", "r", encoding="utf-8") as handle:
        boot_id = handle.read().strip() or "unknown"
except OSError:
    # `monotonic_ns` restarts at boot. Use a minute-rounded boot epoch on
    # non-Linux hosts so sequence comparison never treats a reboot as the same
    # stream merely because /proc is absent.
    boot_id = os.environ.get("CMUX_COMPANION_REMOTE_BOOT_ID")
    if not boot_id:
        approximate_boot_minute = int((time.time() - time.monotonic()) // 60)
        boot_id = "epoch-minute-%d" % approximate_boot_minute
boot_id = re.sub(r"[^A-Za-z0-9._-]", "_", str(boot_id or "unknown"))[:128] or "unknown"
event_id = uuid.uuid4().hex

native_session = (
    native.get("session_id")
    or native.get("sessionId")
    or native.get("conversation_id")
    or native.get("thread_id")
    or os.environ.get("CMUX_REMOTE_SESSION_ID")
    or "%s:%s" % (host, source)
)
native_session = limited_identifier(native_session, "%s:%s" % (host, source))
encoded_surface = urllib.parse.quote(str(surface), safe="")
managed_session_prefix = "cmux-remote:v2:%s:" % encoded_surface
if native_session.startswith(managed_session_prefix):
    session = native_session
else:
    session = "%s%s" % (managed_session_prefix, native_session)

native_tool_name = native.get("tool_name") or native.get("toolName")
marker_needed = is_actionable_telemetry or original_hook_name == "Heartbeat"
tool_name = (
    "cmux-companion-remote-event:%s" % original_hook_name
    if marker_needed
    else native_tool_name
)
sequence_marker = "cmux-companion-seq:%s:%d:%s" % (boot_id, sequence, event_id)

try:
    fallback_cwd = os.getcwd()
except OSError:
    fallback_cwd = ""

event = {
    "session_id": str(session),
    "hook_event_name": wire_hook_name,
    "_source": str(source),
    "workspace_id": workspace,
    "surface_id": surface,
    "cwd": str(native.get("cwd") or fallback_cwd)[:4096],
    "_received_at": received_at,
    "_opencode_request_id": sequence_marker,
    # Retained as requested for Feed/audit payloads. cmux 0.64 redacts unknown
    # event fields from its public event stream, so tool_name above is the
    # non-sensitive visible carrier used by the Companion fallback parser.
    "_cmux_companion_original_event": original_hook_name,
    "_cmux_companion_remote": {
        "version": 2,
        "remote": True,
        "host": host,
        "user": os.environ.get("USER") or os.environ.get("LOGNAME"),
        "workspace_id": workspace,
        "surface_id": surface,
        "native_session_id": native_session,
        "native_request_id": native.get("_opencode_request_id"),
        "native_received_at": native.get("_received_at"),
        "native_tool_name": native_tool_name,
        "original_hook_event": original_hook_name,
        "event_sequence": sequence,
        "remote_boot_id": boot_id,
        "event_id": event_id,
        "heartbeat_at": now.isoformat().replace("+00:00", "Z"),
    },
}
if tool_name is not None:
    event["tool_name"] = str(tool_name)[:512]

if original_hook_name == "UserPromptSubmit":
    prompt = native.get("prompt") or native.get("message") or native.get("text")
    if prompt is None:
        native_tool_input = native.get("tool_input")
        if isinstance(native_tool_input, dict):
            prompt = (
                native_tool_input.get("prompt")
                or native_tool_input.get("text")
                or native_tool_input.get("message")
            )
        elif isinstance(native_tool_input, str):
            prompt = native_tool_input
    if prompt is not None:
        prompt = str(prompt)[:MAX_PROMPT_CHARS]
        event["tool_input"] = {"prompt": prompt}
        event["context"] = {"lastUserMessage": prompt}
elif marker_needed:
    event["tool_input"] = {
        "kind": "remote_agent_state",
        "original_hook_event": original_hook_name,
        "telemetry_only": True,
    }

payload = json.dumps(
    {"event": event, "wait_timeout_seconds": 0},
    ensure_ascii=False,
    separators=(",", ":"),
)

cmux_cli = os.environ["CMUX_COMPANION_REMOTE_CMUX_CLI"]
timeout_ms = bounded_int("CMUX_COMPANION_HOOK_RPC_TIMEOUT_MS", 900, 100, 2000)
attempts = bounded_int("CMUX_COMPANION_HOOK_RPC_ATTEMPTS", 2, 1, 3)
failure = "unknown"
for attempt in range(attempts):
    try:
        result = subprocess.run(
            [cmux_cli, "rpc", "feed.push", payload],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout_ms / 1000.0,
            check=False,
        )
        if result.returncode == 0:
            raise SystemExit(0)
        failure = "cmux rpc exited %d" % result.returncode
    except subprocess.TimeoutExpired:
        failure = "cmux rpc timed out after %dms" % timeout_ms
    except OSError as error:
        failure = "cmux rpc launch failed: %s" % type(error).__name__
    if attempt + 1 < attempts:
        time.sleep(0.08 * (attempt + 1))

record_failure(failure, original_hook_name)
raise SystemExit(0)
' || {
    # Encoding/runtime failures are diagnostic only; never fail the agent hook.
    warn "failed to encode or deliver hook telemetry"
    exit 0
}

exit 0
