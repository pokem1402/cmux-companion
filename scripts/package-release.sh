#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
dist_dir="$project_root/dist"
source_app="$dist_dir/CmuxCompanion.app"
release_dir="$dist_dir/release"
expected_bundle_id=dev.cmuxcompanion.app
release_arch=arm64
temporary_root=""
published_archive_tmp=""
published_checksum_tmp=""

fail() {
    printf '%s\n' "package-release: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$published_archive_tmp" && -e "$published_archive_tmp" ]]; then
        rm -f -- "$published_archive_tmp"
    fi
    if [[ -n "$published_checksum_tmp" && -e "$published_checksum_tmp" ]]; then
        rm -f -- "$published_checksum_tmp"
    fi
    if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT HUP INT TERM

if [[ $# -ne 0 ]]; then
    printf '%s\n' "Usage: package-release.sh" >&2
    exit 2
fi

for required_tool in chflags codesign ditto lipo plutil shasum xattr zipinfo; do
    command -v "$required_tool" >/dev/null 2>&1 \
        || fail "required tool is unavailable: $required_tool"
done

is_semantic_version() {
    local value=$1
    local core_number='(0|[1-9][0-9]*)'
    local identifier='[0-9A-Za-z-]+'
    local pattern="^${core_number}[.]${core_number}[.]${core_number}([-]${identifier}([.]${identifier})*)?([+]${identifier}([.]${identifier})*)?$"
    local precedence prerelease identifier_value
    local -a identifiers

    [[ "$value" =~ $pattern ]] || return 1

    # SemVer rejects leading zeroes in numeric prerelease identifiers.
    precedence=${value%%+*}
    if [[ "$precedence" == *-* ]]; then
        prerelease=${precedence#*-}
        IFS='.' read -r -a identifiers <<< "$prerelease"
        for identifier_value in "${identifiers[@]}"; do
            if [[ "$identifier_value" =~ ^[0-9]+$ ]] \
                && [[ ${#identifier_value} -gt 1 ]] \
                && [[ "$identifier_value" == 0* ]]; then
                return 1
            fi
        done
    fi
    return 0
}

plist_value() {
    local key=$1
    local plist=$2
    plutil -extract "$key" raw "$plist" 2>/dev/null \
        || fail "missing $key in $plist"
}

validate_bundle() {
    local app=$1
    local expected_version=$2
    local expected_build=$3
    local expected_channel=$4
    local plist="$app/Contents/Info.plist"
    local main_executable="$app/Contents/MacOS/CmuxCompanion"
    local helper_executable="$app/Contents/MacOS/cmux-set"
    local installer="$app/Contents/Resources/scripts/install-local.sh"
    local actual_id actual_version actual_build actual_channel actual_archs unsafe_entry

    [[ -d "$app" ]] || fail "app bundle is missing: $app"
    [[ -f "$plist" ]] || fail "Info.plist is missing: $plist"
    plutil -lint "$plist" >/dev/null || fail "Info.plist is invalid: $plist"

    actual_id=$(plist_value CFBundleIdentifier "$plist")
    actual_version=$(plist_value CFBundleShortVersionString "$plist")
    actual_build=$(plist_value CFBundleVersion "$plist")
    actual_channel=$(plist_value CmuxCompanionUpdateChannel "$plist")
    [[ "$actual_id" == "$expected_bundle_id" ]] \
        || fail "unexpected bundle identifier: $actual_id"
    [[ "$actual_version" == "$expected_version" ]] \
        || fail "bundle version changed during packaging: $actual_version"
    [[ "$actual_build" == "$expected_build" ]] \
        || fail "bundle build changed during packaging: $actual_build"
    [[ "$actual_channel" == "$expected_channel" ]] \
        || fail "bundle update channel changed during packaging: $actual_channel"

    [[ -x "$main_executable" ]] || fail "main executable is missing or not executable"
    [[ -x "$helper_executable" ]] || fail "cmux-set is missing or not executable"
    [[ -x "$installer" ]] || fail "embedded install-local.sh is missing or not executable"

    actual_archs=$(lipo -archs "$main_executable" 2>/dev/null) \
        || fail "could not inspect app architecture"
    [[ "$actual_archs" == "$release_arch" ]] \
        || fail "release must contain exactly $release_arch, found: $actual_archs"

    unsafe_entry=$(find "$app" ! -type d ! -type f -print -quit)
    [[ -z "$unsafe_entry" ]] \
        || fail "bundle contains a symlink or special file: $unsafe_entry"

    codesign --verify --deep --strict "$app" \
        || fail "bundle failed code-signature verification: $app"
}

"$script_dir/package-app.sh"

[[ -d "$source_app" ]] || fail "package-app.sh did not create $source_app"
source_plist="$source_app/Contents/Info.plist"
version=$(plist_value CFBundleShortVersionString "$source_plist")
build=$(plist_value CFBundleVersion "$source_plist")
channel=$(plist_value CmuxCompanionUpdateChannel "$source_plist")

is_semantic_version "$version" \
    || fail "CFBundleShortVersionString must be strict SemVer without a leading v: $version"
[[ "$build" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be numeric: $build"
case "$channel" in
    stable|preview) ;;
    *) fail "unexpected update channel: $channel" ;;
esac

archive_name="CmuxCompanion-v${version}-macos-${release_arch}.zip"
checksum_name="${archive_name}.sha256"
temporary_base=${TMPDIR:-/tmp}
temporary_base=${temporary_base%/}
temporary_root=$(mktemp -d "$temporary_base/CmuxCompanion.release.XXXXXX")
staging_dir="$temporary_root/staging"
staged_app="$staging_dir/CmuxCompanion.app"
archive_path="$temporary_root/$archive_name"
checksum_path="$temporary_root/$checksum_name"
extraction_dir="$temporary_root/extracted"
mkdir -p "$staging_dir" "$extraction_dir"

# Do not carry Finder, quarantine, resource-fork, or File Provider metadata into
# the release archive. Code-signature files inside the app bundle are retained.
copy_diagnostics="$temporary_root/ditto-copy.log"
if ! ditto --norsrc --noextattr --noqtn "$source_app" "$staged_app" \
    2>"$copy_diagnostics"; then
    # File Provider can race package-app.sh by reattaching protected metadata
    # and make ditto report EPERM after it has copied all sealed bundle files.
    # Never trust that partial success: the signature and every required file
    # are validated below before an archive can be produced.
    printf '%s\n' \
        "package-release: ditto reported source metadata warnings; validating the copied bundle" \
        >&2
fi
chflags -R nohidden "$staged_app" 2>/dev/null || true
xattr -cr "$staged_app" 2>/dev/null || true
validate_bundle "$staged_app" "$version" "$build" "$channel"

ditto -c -k --norsrc --noextattr --keepParent "$staged_app" "$archive_path"

archive_entry_count=0
while IFS= read -r archive_entry; do
    [[ -n "$archive_entry" ]] || fail "archive contains an empty entry name"
    archive_entry_count=$((archive_entry_count + 1))
    case "$archive_entry" in
        CmuxCompanion.app|CmuxCompanion.app/*) ;;
        *) fail "archive contains an unexpected root entry: $archive_entry" ;;
    esac
    normalized_archive_entry=${archive_entry%/}
    case "/$normalized_archive_entry/" in
        *'/../'*|*'/./'*|*'//'*) fail "archive contains an unsafe path: $archive_entry" ;;
    esac
    case "$archive_entry" in
        *'\\'*) fail "archive contains a backslash path: $archive_entry" ;;
    esac
done < <(zipinfo -1 "$archive_path")
[[ "$archive_entry_count" -gt 0 ]] || fail "archive is empty"

ditto -x -k "$archive_path" "$extraction_dir"
root_entry_count=$(find "$extraction_dir" -mindepth 1 -maxdepth 1 -print \
    | wc -l \
    | tr -d '[:space:]')
[[ "$root_entry_count" == "1" ]] \
    || fail "archive must extract to exactly one top-level entry"
validate_bundle "$extraction_dir/CmuxCompanion.app" "$version" "$build" "$channel"

checksum_output=$(shasum -a 256 "$archive_path")
checksum=${checksum_output%%[[:space:]]*}
[[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] || fail "could not compute a SHA-256 digest"
checksum=$(printf '%s' "$checksum" | tr '[:upper:]' '[:lower:]')
printf '%s  %s\n' "$checksum" "$archive_name" > "$checksum_path"

(
    CDPATH= cd -- "$temporary_root"
    shasum -a 256 -c "$checksum_name"
)

mkdir -p "$release_dir"
published_archive_tmp="$release_dir/.${archive_name}.tmp.$$"
published_checksum_tmp="$release_dir/.${checksum_name}.tmp.$$"
install -m 0644 "$archive_path" "$published_archive_tmp"
install -m 0644 "$checksum_path" "$published_checksum_tmp"
mv -f -- "$published_archive_tmp" "$release_dir/$archive_name"
published_archive_tmp=""
mv -f -- "$published_checksum_tmp" "$release_dir/$checksum_name"
published_checksum_tmp=""

(
    CDPATH= cd -- "$release_dir"
    shasum -a 256 -c "$checksum_name"
)

printf '%s\n' "Release archive:  $release_dir/$archive_name"
printf '%s\n' "SHA-256 sidecar: $release_dir/$checksum_name"
printf '%s\n' "Bundle: $expected_bundle_id v$version ($build), $channel, $release_arch"
