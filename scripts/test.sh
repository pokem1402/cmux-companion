#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_root="$project_root/.build"
mkdir -p "$build_root/module-cache" "$build_root/swiftpm-cache" \
    "$build_root/swiftpm-config" "$build_root/swiftpm-security"

export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFT_MODULE_CACHE_PATH="$build_root/module-cache"

swift_arguments=(
    --package-path "$project_root"
    --disable-sandbox
    --cache-path "$build_root/swiftpm-cache"
    --config-path "$build_root/swiftpm-config"
    --security-path "$build_root/swiftpm-security"
)

sdk_path=${CMUX_COMPANION_SDK:-}
if [[ -z "$sdk_path" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
if [[ -n "$sdk_path" ]]; then
    swift_arguments+=(--sdk "$sdk_path" --triple "$(uname -m)-apple-macosx14.0")
fi

swift build "${swift_arguments[@]}"
bin_path=$(swift build "${swift_arguments[@]}" --show-bin-path)
"$bin_path/cmux-companion-selftest"

# AppKit can detach its stdio from a non-bundled SwiftPM invocation. Run the
# UI self-test under an explicit PID/marker check so an early launch return or
# a stuck item-provider callback can never look like a passing test.
drag_output=$(mktemp "${TMPDIR:-/tmp}/cmux-companion-drag-selftest.XXXXXX")
drag_pid=""
cleanup_drag_test() {
    if [[ -n "$drag_pid" ]] && kill -0 "$drag_pid" 2>/dev/null; then
        kill "$drag_pid" 2>/dev/null || true
        wait "$drag_pid" 2>/dev/null || true
    fi
    rm -f "$drag_output"
}
trap cleanup_drag_test EXIT

"$bin_path/CmuxCompanion" --self-test-drag-and-drop >"$drag_output" 2>&1 &
drag_pid=$!
for _ in $(seq 1 150); do
    if ! kill -0 "$drag_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if kill -0 "$drag_pid" 2>/dev/null; then
    printf '%s\n' "Cmux Companion drag-and-drop self-test: FAIL: timed out" >&2
    sed -n '1,200p' "$drag_output" >&2
    exit 1
fi

set +e
wait "$drag_pid"
drag_status=$?
set -e
drag_pid=""
sed -n '1,200p' "$drag_output"
if [[ "$drag_status" -ne 0 ]] || ! grep -Fq \
    "Cmux Companion drag-and-drop self-test: PASS" "$drag_output"; then
    printf '%s\n' "Cmux Companion drag-and-drop self-test did not report PASS" >&2
    exit 1
fi
rm -f "$drag_output"
trap - EXIT

bash -n "$script_dir/package-app.sh"
bash -n "$script_dir/install-local.sh"
sh -n "$script_dir/remote-hook-bridge.sh"
sh -n "$script_dir/install-remote-hooks.sh"
zsh -n "$script_dir/shell-command-hook.zsh"
sh -n "$script_dir/test-remote-hooks.sh"
"$script_dir/test-remote-hooks.sh"

printf '%s\n' "Cmux Companion checks: PASS"
