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
"$bin_path/CmuxCompanion" --self-test-drag-and-drop

bash -n "$script_dir/package-app.sh"
bash -n "$script_dir/install-local.sh"
sh -n "$script_dir/remote-hook-bridge.sh"
sh -n "$script_dir/install-remote-hooks.sh"
zsh -n "$script_dir/shell-command-hook.zsh"
sh -n "$script_dir/test-remote-hooks.sh"
"$script_dir/test-remote-hooks.sh"

printf '%s\n' "Cmux Companion checks: PASS"
