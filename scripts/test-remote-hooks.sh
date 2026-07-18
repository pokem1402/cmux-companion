#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bridge="$script_dir/remote-hook-bridge.sh"
installer="$script_dir/install-remote-hooks.sh"

python_cli=$(command -v python3 2>/dev/null || true)
if [ -z "$python_cli" ]; then
    printf '%s\n' "test-remote-hooks: Python 3 is required" >&2
    exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/cmux-companion-remote-tests.XXXXXX")
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

fake_cmux="$test_root/fake-cmux"
cat > "$fake_cmux" <<'EOF'
#!/bin/sh
set -eu
counter_file=${CMUX_FAKE_COUNTER:?}
capture_file=${CMUX_FAKE_CAPTURE:?}
count=0
if [ -f "$counter_file" ]; then
    IFS= read -r count < "$counter_file" || count=0
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
if [ "$count" -le "${CMUX_FAKE_FAIL_UNTIL:-0}" ]; then
    exit 75
fi
{
    printf '%s\n' "$1"
    printf '%s\n' "$2"
    printf '%s\n' "$3"
} > "$capture_file"
EOF
chmod 0755 "$fake_cmux"

counter="$test_root/counter"
capture="$test_root/capture"
state_home="$test_root/state"

# First delivery fails and the bounded foreground retry succeeds. The original
# actionable kind must remain metadata while the actual Feed kind is telemetry.
printf '%s' '{"session_id":"native-session","hook_event_name":"PermissionRequest","tool_name":"Bash","_opencode_request_id":"native-request","_received_at":"native-time","_ppid":4321}' |
    HOME="$test_root/home" \
    XDG_STATE_HOME="$state_home" \
    CMUX_FAKE_COUNTER="$counter" \
    CMUX_FAKE_CAPTURE="$capture" \
    CMUX_FAKE_FAIL_UNTIL=1 \
    CMUX_BUNDLED_CLI_PATH="$fake_cmux" \
    CMUX_SOCKET_PATH=127.0.0.1:43123 \
    CMUX_WORKSPACE_ID=workspace-1 \
    CMUX_SURFACE_ID=surface-1 \
    CMUX_COMPANION_HOOK_RPC_TIMEOUT_MS=500 \
    CMUX_COMPANION_HOOK_RPC_ATTEMPTS=2 \
    "$bridge" --source codex

[ "$(cat "$counter")" = "2" ]
"$python_cli" - "$capture" <<'PY'
import json
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert lines[:2] == ["rpc", "feed.push"]
payload = json.loads(lines[2])
event = payload["event"]
assert payload["wait_timeout_seconds"] == 0
assert event["hook_event_name"] == "Notification"
assert event["_cmux_companion_original_event"] == "PermissionRequest"
assert event["tool_name"] == "cmux-companion-remote-event:PermissionRequest"
assert event["session_id"] == "cmux-remote:surface-1:native-session"
assert event["_opencode_request_id"].startswith("cmux-companion-seq:")
assert isinstance(event["_received_at"], (int, float))
assert "_ppid" not in event
metadata = event["_cmux_companion_remote"]
assert metadata["native_request_id"] == "native-request"
assert metadata["native_received_at"] == "native-time"
assert metadata["native_tool_name"] == "Bash"
assert metadata["original_hook_event"] == "PermissionRequest"
assert event["tool_input"]["telemetry_only"] is True
PY

# User prompt content remains available to feed.list, but arbitrary native hook
# fields and remote process IDs are not forwarded.
printf '%s' '{"session_id":"prompt-session","hook_event_name":"UserPromptSubmit","prompt":"review PR 142","_ppid":99,"unrelated_secret":"do-not-forward"}' |
    HOME="$test_root/home" \
    XDG_STATE_HOME="$state_home" \
    CMUX_FAKE_COUNTER="$test_root/prompt-counter" \
    CMUX_FAKE_CAPTURE="$test_root/prompt-capture" \
    CMUX_BUNDLED_CLI_PATH="$fake_cmux" \
    CMUX_SOCKET_PATH=127.0.0.1:43123 \
    CMUX_WORKSPACE_ID=workspace-1 \
    CMUX_SURFACE_ID=surface-1 \
    "$bridge" --source codex

"$python_cli" - "$test_root/prompt-capture" <<'PY'
import json
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
event = json.loads(lines[2])["event"]
assert event["hook_event_name"] == "UserPromptSubmit"
assert event["tool_input"]["prompt"] == "review PR 142"
assert event["context"]["lastUserMessage"] == "review PR 142"
assert "_ppid" not in event
assert "unrelated_secret" not in event
PY

# Heartbeats travel as ordinary SessionStart feed telemetry, while the visible
# carrier preserves Heartbeat so the app refreshes liveness without guessing.
printf '%s' '{}' |
    HOME="$test_root/home" \
    XDG_STATE_HOME="$state_home" \
    CMUX_FAKE_COUNTER="$test_root/heartbeat-counter" \
    CMUX_FAKE_CAPTURE="$test_root/heartbeat-capture" \
    CMUX_BUNDLED_CLI_PATH="$fake_cmux" \
    CMUX_SOCKET_PATH=127.0.0.1:43123 \
    CMUX_WORKSPACE_ID=workspace-1 \
    CMUX_SURFACE_ID=surface-1 \
    "$bridge" --source codex --heartbeat

"$python_cli" - "$test_root/heartbeat-capture" <<'PY'
import json
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
event = json.loads(lines[2])["event"]
assert event["hook_event_name"] == "SessionStart"
assert event["_cmux_companion_original_event"] == "Heartbeat"
assert event["tool_name"] == "cmux-companion-remote-event:Heartbeat"
assert event["tool_input"]["telemetry_only"] is True
PY

# Exhausted retries remain non-fatal but leave a prompt-free operational log,
# so a relay outage is diagnosable instead of being a silent telemetry loss.
failure_state="$test_root/failure-state"
printf '%s' '{"session_id":"failure-session","hook_event_name":"UserPromptSubmit","prompt":"never-log-this-secret"}' |
    HOME="$test_root/home" \
    XDG_STATE_HOME="$failure_state" \
    CMUX_FAKE_COUNTER="$test_root/failure-counter" \
    CMUX_FAKE_CAPTURE="$test_root/failure-capture" \
    CMUX_FAKE_FAIL_UNTIL=9 \
    CMUX_BUNDLED_CLI_PATH="$fake_cmux" \
    CMUX_SOCKET_PATH=127.0.0.1:43123 \
    CMUX_WORKSPACE_ID=workspace-1 \
    CMUX_SURFACE_ID=surface-1 \
    CMUX_COMPANION_HOOK_RPC_ATTEMPTS=2 \
    "$bridge" --source codex
[ "$(cat "$test_root/failure-counter")" = "2" ]
failure_log="$failure_state/cmux-companion/remote-hook-errors.log"
[ -s "$failure_log" ]
grep -F 'event=UserPromptSubmit' "$failure_log" >/dev/null
if grep -F 'never-log-this-secret' "$failure_log" >/dev/null; then
    printf '%s\n' "test-remote-hooks: failure log leaked prompt text" >&2
    exit 1
fi

# A Unix socket path must never be accepted by the remote-only bridge.
printf '%s' '{}' |
    HOME="$test_root/home" \
    XDG_STATE_HOME="$state_home" \
    CMUX_FAKE_COUNTER="$test_root/rejected-counter" \
    CMUX_FAKE_CAPTURE="$test_root/rejected-capture" \
    CMUX_BUNDLED_CLI_PATH="$fake_cmux" \
    CMUX_SOCKET_PATH="$test_root/local.sock" \
    CMUX_WORKSPACE_ID=workspace-1 \
    CMUX_SURFACE_ID=surface-1 \
    "$bridge" --source codex --heartbeat
[ ! -e "$test_root/rejected-counter" ]

# Dangerous or shared prefixes fail before mkdir/install. The normal default
# still creates only the three managed files under ~/.local.
test_home="$test_root/home"
mkdir -p "$test_home"
if HOME="$test_home" "$installer" --prefix '' --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: empty prefix was accepted" >&2
    exit 1
fi
if HOME="$test_home" "$installer" --prefix / --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: root prefix was accepted" >&2
    exit 1
fi
if HOME="$test_home" "$installer" --prefix relative/path --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: relative prefix was accepted" >&2
    exit 1
fi
if HOME="$test_home" "$installer" --prefix /usr/local --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: shared /usr/local prefix was accepted" >&2
    exit 1
fi

outside_prefix="$test_root/outside"
mkdir -p "$outside_prefix"
ln -s "$outside_prefix" "$test_home/escape"
if HOME="$test_home" "$installer" \
    --prefix "$test_home/escape/cmux-companion" --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: symlink escape outside HOME was accepted" >&2
    exit 1
fi

# A safe prefix can still contain child-directory symlinks. Both binary and
# library target parents must be resolved before mkdir/install so neither can
# redirect managed files outside HOME or leave a partial installation behind.
bin_escape_home="$test_root/bin-escape-home"
bin_escape_target="$test_root/bin-escape-target"
mkdir -p "$bin_escape_home/.local" "$bin_escape_target"
ln -s "$bin_escape_target" "$bin_escape_home/.local/bin"
if HOME="$bin_escape_home" "$installer" \
    --prefix "$bin_escape_home/.local" --agent codex --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: .local/bin symlink escape outside HOME was accepted" >&2
    exit 1
fi
[ ! -e "$bin_escape_target/cmux-companion-remote-codex-hook" ]
[ ! -e "$bin_escape_home/.local/lib/cmux-companion/remote-hook-bridge.sh" ]

lib_escape_home="$test_root/lib-escape-home"
lib_escape_target="$test_root/lib-escape-target"
mkdir -p "$lib_escape_home/.local" "$lib_escape_target"
ln -s "$lib_escape_target" "$lib_escape_home/.local/lib"
if HOME="$lib_escape_home" "$installer" \
    --prefix "$lib_escape_home/.local" --agent codex --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: .local/lib symlink escape outside HOME was accepted" >&2
    exit 1
fi
[ ! -e "$lib_escape_target/cmux-companion/remote-hook-bridge.sh" ]
[ ! -e "$lib_escape_home/.local/bin/cmux-companion-remote-codex-hook" ]

# Even HOME-internal child symlinks are unsafe when bin and lib resolve to
# separate physical parents: the wrapper intentionally executes ../lib/....
# Reject that layout instead of reporting a successful but unusable install.
split_layout_home="$test_root/split-layout-home"
mkdir -p \
    "$split_layout_home/.local" \
    "$split_layout_home/physical-bin" \
    "$split_layout_home/physical-lib"
ln -s "$split_layout_home/physical-bin" "$split_layout_home/.local/bin"
ln -s "$split_layout_home/physical-lib" "$split_layout_home/.local/lib"
if HOME="$split_layout_home" "$installer" \
    --prefix "$split_layout_home/.local" --agent codex --install >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: split canonical bin/lib layout was accepted" >&2
    exit 1
fi
[ ! -e "$split_layout_home/physical-bin/cmux-companion-remote-codex-hook" ]
[ ! -e "$split_layout_home/physical-lib/cmux-companion/remote-hook-bridge.sh" ]

install_prefix="$test_home/.local"
HOME="$test_home" "$installer" --agent all --install >/dev/null
[ -x "$install_prefix/lib/cmux-companion/remote-hook-bridge.sh" ]
[ -x "$install_prefix/bin/cmux-companion-remote-codex-hook" ]
[ -x "$install_prefix/bin/cmux-companion-remote-claude-hook" ]

# A successful normal install must also be executable, not merely present.
normal_wrapper_output=$(HOME="$test_home" \
    "$install_prefix/bin/cmux-companion-remote-codex-hook" --help)
case "$normal_wrapper_output" in
    *"Usage: remote-hook-bridge.sh"*) ;;
    *)
        printf '%s\n' "test-remote-hooks: installed wrapper could not execute its bridge" >&2
        exit 1
        ;;
esac

# All target conflicts are checked before any managed file is updated.
printf '%s\n' '# retained-old-managed-copy' >> \
    "$install_prefix/lib/cmux-companion/remote-hook-bridge.sh"
printf '%s\n' '#!/bin/sh' '# user-owned-wrapper' > \
    "$install_prefix/bin/cmux-companion-remote-claude-hook"
if HOME="$test_home" "$installer" \
    --prefix "$install_prefix" --agent all --update-managed >/dev/null 2>&1; then
    printf '%s\n' "test-remote-hooks: unmanaged wrapper was overwritten" >&2
    exit 1
fi
grep -F '# retained-old-managed-copy' \
    "$install_prefix/lib/cmux-companion/remote-hook-bridge.sh" >/dev/null

printf '%s\n' "Remote hook checks: PASS"
