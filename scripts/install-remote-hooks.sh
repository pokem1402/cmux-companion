#!/bin/sh
# Installs only cmux-companion-owned wrappers. Agent configuration files are
# intentionally never edited or overwritten by this script.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bridge_source="$script_dir/remote-hook-bridge.sh"
prefix=${HOME}/.local
agent=all
do_install=0
update_managed=0

usage() {
    cat <<'EOF'
Usage: install-remote-hooks.sh [options]

Safe default: dry-run only. This script never changes Codex or Claude config.

Options:
  --install              Install new managed bridge/wrapper files
  --update-managed       Install missing files and update managed existing files
  --prefix <path>        Install root below HOME (default: ~/.local)
  --agent codex|claude|all
  -h, --help             Show this help
EOF
}

die() {
    printf '%s\n' "install-remote-hooks: $*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install)
            do_install=1
            shift
            ;;
        --update-managed)
            do_install=1
            update_managed=1
            shift
            ;;
        --prefix)
            [ "$#" -ge 2 ] || die "--prefix requires a path"
            prefix=$2
            shift 2
            ;;
        --agent)
            [ "$#" -ge 2 ] || die "--agent requires codex, claude, or all"
            agent=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

case "$agent" in
    codex|claude|all) ;;
    *) die "unsupported agent: $agent" ;;
esac

# These wrappers are per-user agent hooks. A blank prefix expands to /bin and
# /lib below, while root execution turns a typo into a system-wide overwrite.
# Reject both rather than relying on the caller remembering not to use sudo.
if [ "$(id -u)" -eq 0 ]; then
    die "refusing to install agent hooks as root; run as the remote agent user"
fi
while [ "${prefix%/}" != "$prefix" ]; do
    prefix=${prefix%/}
done
if [ -z "$prefix" ]; then
    die "--prefix must not be empty or filesystem root"
fi
case "$prefix" in
    /*) ;;
    *) die "--prefix must be an absolute per-user path" ;;
esac
case "/$prefix/" in
    */../*|*/./*) die "--prefix must not contain . or .. path components" ;;
esac

# Resolve the deepest existing ancestor without creating anything. `pwd -P`
# follows every existing symlink component, while the suffix is known not to
# contain dot components. This catches paths such as ~/safe-link/new when the
# link actually escapes into /usr/local or another user's directory.
canonicalize_directory_target() (
    target=$1
    suffix=""
    probe=$target

    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
        component=${probe##*/}
        [ -n "$component" ] || exit 1
        suffix="/$component$suffix"
        parent=${probe%/*}
        [ -n "$parent" ] || parent=/
        [ "$parent" != "$probe" ] || exit 1
        probe=$parent
    done

    # A dangling symlink or regular file cannot be an install-directory
    # ancestor. A symlink to a directory is intentionally resolved by cd -P.
    [ -d "$probe" ] || exit 1
    physical=$(CDPATH= cd -- "$probe" 2>/dev/null && pwd -P) || exit 1
    case "$physical" in
        /) printf '/%s\n' "${suffix#/}" ;;
        *) printf '%s%s\n' "$physical" "$suffix" ;;
    esac
)

case ${HOME:-} in
    /*) ;;
    *) die "HOME must be an absolute existing user directory" ;;
esac
[ -d "$HOME" ] || die "HOME must be an absolute existing user directory"
canonical_home=$(canonicalize_directory_target "$HOME") \
    || die "could not resolve HOME safely"
canonical_prefix=$(canonicalize_directory_target "$prefix") \
    || die "could not resolve --prefix safely"
if [ "$canonical_prefix" = "$canonical_home" ]; then
    die "--prefix must be a dedicated directory below HOME"
fi
case "$canonical_prefix" in
    "$canonical_home"/*) ;;
    *) die "--prefix must resolve to a per-user directory below HOME" ;;
esac

# The prefix itself being safe is not sufficient: ~/.local/bin or ~/.local/lib
# may already be a symlink. Resolve every install directory/target parent too,
# both before creating directories and immediately before publishing a file.
require_home_subdirectory() {
    checked_path=$1
    checked_label=$2
    canonical_checked=$(canonicalize_directory_target "$checked_path") \
        || die "could not resolve $checked_label safely: $checked_path"
    if [ "$canonical_checked" = "$canonical_home" ]; then
        die "$checked_label must be a dedicated directory below HOME: $checked_path"
    fi
    case "$canonical_checked" in
        "$canonical_home"/*) ;;
        *) die "$checked_label must resolve below HOME: $checked_path" ;;
    esac
}

require_canonical_layout() {
    layout_path=$1
    expected_canonical_path=$2
    layout_label=$3
    actual_canonical_path=$(canonicalize_directory_target "$layout_path") \
        || die "could not resolve $layout_label safely: $layout_path"
    if [ "$actual_canonical_path" != "$expected_canonical_path" ]; then
        die "$layout_label must preserve the canonical prefix layout: $layout_path"
    fi
}

preflight_target_parent() {
    checked_target=$1
    checked_parent=${checked_target%/*}
    [ -n "$checked_parent" ] && [ "$checked_parent" != "$checked_target" ] \
        || die "could not determine target parent safely: $checked_target"
    require_home_subdirectory "$checked_parent" "target parent"
    case "$checked_parent" in
        "$lib_dir")
            require_canonical_layout \
                "$checked_parent" "$canonical_prefix/lib/cmux-companion" "library target parent"
            ;;
        "$bin_dir")
            require_canonical_layout \
                "$checked_parent" "$canonical_prefix/bin" "binary target parent"
            ;;
        *) die "unexpected target parent: $checked_parent" ;;
    esac
}

[ -f "$bridge_source" ] || die "bridge source not found: $bridge_source"

lib_dir="$prefix/lib/cmux-companion"
bin_dir="$prefix/bin"
bridge_target="$lib_dir/remote-hook-bridge.sh"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-companion-hooks.XXXXXX")
cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

make_wrapper() {
    wrapper_agent=$1
    wrapper_path=$2
    cat > "$wrapper_path" <<EOF
#!/bin/sh
# cmux-companion-managed-wrapper v1
set -eu
self_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
exec "\$self_dir/../lib/cmux-companion/remote-hook-bridge.sh" --source "$wrapper_agent" "\$@"
EOF
    chmod 0755 "$wrapper_path"
}

make_wrapper codex "$temp_dir/cmux-companion-remote-codex-hook"
make_wrapper claude "$temp_dir/cmux-companion-remote-claude-hook"

preflight_one() {
    source_file=$1
    target_file=$2
    marker_kind=$3

    if [ -L "$target_file" ]; then
        die "refusing to overwrite a symlink: $target_file"
    fi
    if [ -e "$target_file" ]; then
        if cmp -s "$source_file" "$target_file"; then
            return
        fi
        if [ "$update_managed" -ne 1 ]; then
            die "refusing to overwrite existing file: $target_file (use --update-managed)"
        fi
        if [ ! -f "$target_file" ]; then
            die "refusing to overwrite a non-regular file: $target_file"
        fi
        case "$marker_kind" in
            bridge)
                marker_ok=$(sed -n '2p' "$target_file" | grep -E '^# cmux-companion-managed-remote-hook v[0-9]+$' || true)
                ;;
            wrapper)
                marker_ok=$(sed -n '2p' "$target_file" | grep -F -x '# cmux-companion-managed-wrapper v1' || true)
                ;;
            *) marker_ok="" ;;
        esac
        if [ -z "$marker_ok" ]; then
            die "refusing to overwrite unmanaged file: $target_file"
        fi
    fi
}

install_one() {
    source_file=$1
    target_file=$2

    # Re-resolve the parent as late as practical so an existing child symlink
    # can never redirect the staged file outside the canonical HOME tree.
    preflight_target_parent "$target_file"

    if [ -e "$target_file" ] && cmp -s "$source_file" "$target_file"; then
        printf '%s\n' "unchanged: $target_file"
        return
    fi

    temporary_target=$(mktemp "${target_file}.tmp.XXXXXX")
    if ! install -m 0755 "$source_file" "$temporary_target"; then
        rm -f "$temporary_target"
        die "failed to stage: $target_file"
    fi
    if ! mv -f "$temporary_target" "$target_file"; then
        rm -f "$temporary_target"
        die "failed to publish: $target_file"
    fi
    printf '%s\n' "installed: $target_file"
}

if [ "$do_install" -eq 1 ]; then
    # Validate the full directory graph before mkdir so a child symlink cannot
    # cause even a partial install outside HOME.
    require_home_subdirectory "$lib_dir" "library directory"
    require_home_subdirectory "$bin_dir" "binary directory"
    require_canonical_layout \
        "$lib_dir" "$canonical_prefix/lib/cmux-companion" "library directory"
    require_canonical_layout "$bin_dir" "$canonical_prefix/bin" "binary directory"
    preflight_target_parent "$bridge_target"
    case "$agent" in
        codex|all)
            preflight_target_parent "$bin_dir/cmux-companion-remote-codex-hook"
            ;;
    esac
    case "$agent" in
        claude|all)
            preflight_target_parent "$bin_dir/cmux-companion-remote-claude-hook"
            ;;
    esac

    mkdir -p "$lib_dir" "$bin_dir"
    # Resolve again now that previously missing components exist.
    require_home_subdirectory "$lib_dir" "library directory"
    require_home_subdirectory "$bin_dir" "binary directory"
    require_canonical_layout \
        "$lib_dir" "$canonical_prefix/lib/cmux-companion" "library directory"
    require_canonical_layout "$bin_dir" "$canonical_prefix/bin" "binary directory"
    preflight_target_parent "$bridge_target"
    # Validate every selected target before changing any of them. This prevents
    # a late unmanaged wrapper from leaving a half-updated installation.
    preflight_one "$bridge_source" "$bridge_target" bridge
    case "$agent" in
        codex|all)
            preflight_one "$temp_dir/cmux-companion-remote-codex-hook" \
                "$bin_dir/cmux-companion-remote-codex-hook" wrapper
            ;;
    esac
    case "$agent" in
        claude|all)
            preflight_one "$temp_dir/cmux-companion-remote-claude-hook" \
                "$bin_dir/cmux-companion-remote-claude-hook" wrapper
            ;;
    esac

    install_one "$bridge_source" "$bridge_target"
    case "$agent" in
        codex)
            install_one "$temp_dir/cmux-companion-remote-codex-hook" \
                "$bin_dir/cmux-companion-remote-codex-hook"
            ;;
        claude)
            install_one "$temp_dir/cmux-companion-remote-claude-hook" \
                "$bin_dir/cmux-companion-remote-claude-hook"
            ;;
        all)
            install_one "$temp_dir/cmux-companion-remote-codex-hook" \
                "$bin_dir/cmux-companion-remote-codex-hook"
            install_one "$temp_dir/cmux-companion-remote-claude-hook" \
                "$bin_dir/cmux-companion-remote-claude-hook"
            ;;
    esac
else
    printf '%s\n' "Dry run; no files were changed."
    printf '%s\n' "Would install bridge: $bridge_target"
    case "$agent" in
        codex|all) printf '%s\n' "Would install wrapper: $bin_dir/cmux-companion-remote-codex-hook" ;;
    esac
    case "$agent" in
        claude|all) printf '%s\n' "Would install wrapper: $bin_dir/cmux-companion-remote-claude-hook" ;;
    esac
    printf '%s\n' "Re-run with --install after reviewing these paths."
fi

cat <<EOF

Manual agent-hook configuration (this installer does not edit it):
1. Start the remote workspace from the Mac with: cmux ssh <host>
2. Confirm CMUX_WORKSPACE_ID, CMUX_SURFACE_ID, and a loopback
   CMUX_SOCKET_PATH are present in the remote agent environment.
EOF

case "$agent" in
    codex|all)
        cat <<EOF
3. Codex: merge command hooks into ~/.codex/hooks.json under "hooks".
   Recommended event keys:
     SessionStart UserPromptSubmit Stop PreToolUse PostToolUse
     PermissionRequest PreCompact PostCompact SubagentStart SubagentStop
   Command template for each key:
     $bin_dir/cmux-companion-remote-codex-hook --event <EventName>
   Codex command-hook shape:
     {"hooks":[{"type":"command","command":"<command above>","timeout":5}]}
   Enable the Codex hooks feature and approve the new hook when Codex asks.
EOF
        ;;
esac
case "$agent" in
    claude|all)
        cat <<EOF
3. Claude: merge command hooks into ~/.claude/settings.json under "hooks".
   Recommended event keys:
     SessionStart UserPromptSubmit Stop SessionEnd PreToolUse PostToolUse
     PermissionRequest Notification SubagentStart SubagentStop
   Command template for each key:
     $bin_dir/cmux-companion-remote-claude-hook --event <EventName>
   Claude command-hook shape:
     {"matcher":"","hooks":[{"type":"command","command":"<command above>","timeout":5}]}
EOF
        ;;
esac

cat <<'EOF'
The wrapper reads the hook JSON on stdin. If an agent hook does not include a
hook_event_name, add an explicit event, for example:
  cmux-companion-remote-codex-hook --event UserPromptSubmit

Remote permission/question events are status-only telemetry. Approve or answer
them in the original remote agent terminal; the Companion never replies to them.

For one optional heartbeat tick (an agent-owned cadence below 15 minutes keeps
running/unknown state inside the healthy lease):
  printf '{}' | cmux-companion-remote-codex-hook --heartbeat

Diagnostics:
  CMUX_COMPANION_HOOK_DEBUG=1 cmux-companion-remote-codex-hook --heartbeat </dev/null
  tail ~/.local/state/cmux-companion/remote-hook-errors.log
EOF
