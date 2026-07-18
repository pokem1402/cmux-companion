#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_app=${CMUX_COMPANION_SOURCE_APP:-"$project_root/dist/CmuxCompanion.app"}
install_root=${CMUX_COMPANION_INSTALL_DIR:-"$HOME/Applications"}
expected_bundle_id=dev.cmuxcompanion.app
target_app="$install_root/CmuxCompanion.app"
target_executable="$target_app/Contents/MacOS/CmuxCompanion"
launch=0
replace=0
was_running=0
running_pid_hint=${CMUX_COMPANION_RUNNING_PID:-}

usage() {
    cat <<'EOF'
Usage: install-local.sh [--launch] [--replace]

Copies the locally-built app out of a synced/File Provider workspace into
~/Applications, strips inherited metadata from that new copy, ad-hoc signs it,
and verifies the result. Existing unrelated apps are never overwritten.

Options:
  --launch    Open the verified installed copy
  --replace   Replace an existing dev.cmuxcompanion.app installation
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch) launch=1; shift ;;
        --replace) replace=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf '%s\n' "install-local: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -n "$running_pid_hint" && ! "$running_pid_hint" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "install-local: CMUX_COMPANION_RUNNING_PID must be numeric" >&2
    exit 2
fi

if [[ ! -d "$source_app" ]]; then
    printf '%s\n' "install-local: packaged app not found: $source_app" >&2
    printf '%s\n' "Run ./scripts/package-app.sh first." >&2
    exit 1
fi
source_id=$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$source_id" != "$expected_bundle_id" ]]; then
    printf '%s\n' "install-local: source app has unexpected bundle identifier: ${source_id:-missing}" >&2
    exit 1
fi
if [[ ! -x "$source_app/Contents/MacOS/CmuxCompanion" ]]; then
    printf '%s\n' "install-local: source app is missing its executable" >&2
    exit 1
fi

mkdir -p "$install_root"
temporary_app="$install_root/.CmuxCompanion.install.$$.app"
backup_app=""
cleanup() {
    if [[ -e "$temporary_app" ]]; then
        rm -rf "$temporary_app"
    fi
}
trap cleanup EXIT HUP INT TERM

if [[ -e "$target_app" ]]; then
    existing_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing_id" != "$expected_bundle_id" ]]; then
        printf '%s\n' "install-local: refusing to replace unrelated app: $target_app" >&2
        exit 1
    fi
    if [[ "$replace" -ne 1 ]]; then
        printf '%s\n' "install-local: $target_app already exists; pass --replace" >&2
        exit 1
    fi
fi

# `--noextattr --noqtn` prevents the Documents/File Provider metadata that can
# invalidate an otherwise-correct local ad-hoc signature from crossing over.
ditto --noextattr --noqtn "$source_app" "$temporary_app"
xattr -cr "$temporary_app" 2>/dev/null || true
staged_id=$(plutil -extract CFBundleIdentifier raw "$temporary_app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$staged_id" != "$expected_bundle_id" || ! -x "$temporary_app/Contents/MacOS/CmuxCompanion" ]]; then
    printf '%s\n' "install-local: staged app failed identity or executable validation" >&2
    exit 1
fi
codesign --force --deep --sign - "$temporary_app"
codesign --verify --deep --strict "$temporary_app"

# Replacing a running bundle and then using `open -n` leaves the old process
# alive beside the new one. Both instances would drain the same inbox and emit
# duplicate notifications. Stop only the process whose command points at this
# exact installation and relaunch it after the atomic replacement.
running_pids_for_target() {
    local pid command_path
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if [[ -n "$running_pid_hint" && "$pid" == "$running_pid_hint" ]]; then
            kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
            continue
        fi
        command_path=$(ps -p "$pid" -o command= 2>/dev/null || true)
        command_path=${command_path#"${command_path%%[![:space:]]*}"}
        case "$command_path" in
            "$target_executable"|"$target_executable "*) printf '%s\n' "$pid" ;;
        esac
    done < <(
        [[ -n "$running_pid_hint" ]] && printf '%s\n' "$running_pid_hint"
        pgrep -x CmuxCompanion 2>/dev/null || true
    ) | sort -un
}

running_pids=$(running_pids_for_target)
if [[ -n "$running_pids" ]]; then
    was_running=1
    for pid in $running_pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in {1..50}; do
        [[ -z "$(running_pids_for_target)" ]] && break
        sleep 0.1
    done
    if [[ -n "$(running_pids_for_target)" ]]; then
        printf '%s\n' "install-local: running Companion did not quit; installation aborted" >&2
        exit 1
    fi
fi

if [[ -e "$target_app" ]]; then
    backup_app="$install_root/CmuxCompanion.previous.$(date +%Y%m%d-%H%M%S)-$$.app"
    if ! mv "$target_app" "$backup_app"; then
        [[ "$was_running" -eq 1 ]] && open "$target_app" 2>/dev/null || true
        printf '%s\n' "install-local: could not create the recoverable backup" >&2
        exit 1
    fi
fi

rollback_publish() {
    local reason=$1
    local failed_app="$install_root/CmuxCompanion.failed.$(date +%Y%m%d-%H%M%S)-$$.app"
    if [[ -e "$target_app" ]]; then
        mv "$target_app" "$failed_app" 2>/dev/null || true
    fi
    if [[ -n "$backup_app" && -e "$backup_app" ]]; then
        mv "$backup_app" "$target_app" 2>/dev/null || true
    fi
    if [[ "$was_running" -eq 1 && -d "$target_app" ]]; then
        open "$target_app" 2>/dev/null || true
    fi
    printf '%s\n' "install-local: $reason; previous app restored" >&2
    if [[ -e "$failed_app" ]]; then
        printf '%s\n' "Rejected copy kept at: $failed_app" >&2
    fi
}

if ! mv "$temporary_app" "$target_app"; then
    rollback_publish "could not publish staged app"
    exit 1
fi
xattr -dr com.apple.quarantine "$target_app" 2>/dev/null || true
xattr -dr com.apple.FinderInfo "$target_app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$target_app" 2>/dev/null || true
installed_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$installed_id" != "$expected_bundle_id" || ! -x "$target_executable" ]] \
    || ! codesign --verify --deep --strict "$target_app"; then
    rollback_publish "published app failed final verification"
    exit 1
fi
if [[ "$launch" -eq 1 || "$was_running" -eq 1 ]]; then
    if ! open "$target_app"; then
        rollback_publish "new app could not be relaunched"
        exit 1
    fi
fi

trap - EXIT HUP INT TERM

printf '%s\n' "Installed: $target_app"
if [[ -n "$backup_app" ]]; then
    printf '%s\n' "Previous copy kept at: $backup_app"
fi
