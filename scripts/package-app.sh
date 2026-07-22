#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
dist_dir="$project_root/dist"
app_bundle="$dist_dir/CmuxCompanion.app"
bundle_id=${CMUX_COMPANION_BUNDLE_ID:-dev.cmuxcompanion.app}
marketing_version=${CMUX_COMPANION_VERSION:-0.1.10}
build_version=${CMUX_COMPANION_BUILD_NUMBER:-11}
minimum_macos=${CMUX_COMPANION_MIN_MACOS:-14.0}
update_channel=${CMUX_COMPANION_UPDATE_CHANNEL:-preview}

if [[ ! "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf '%s\n' "package-app: invalid bundle identifier: $bundle_id" >&2
    exit 2
fi
if [[ ! "$marketing_version" =~ ^[0-9]+([.][0-9A-Za-z-]+)*$ ]]; then
    printf '%s\n' "package-app: invalid version: $marketing_version" >&2
    exit 2
fi
if [[ ! "$build_version" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "package-app: build number must be numeric" >&2
    exit 2
fi
case "$update_channel" in
    stable|preview) ;;
    *)
        printf '%s\n' "package-app: update channel must be stable or preview" >&2
        exit 2
        ;;
esac

mkdir -p "$dist_dir" "$project_root/.build/module-cache" \
    "$project_root/.build/swiftpm-cache" \
    "$project_root/.build/swiftpm-config" \
    "$project_root/.build/swiftpm-security"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$project_root/.build/module-cache"

swift_arguments=(
    --package-path "$project_root"
    --disable-sandbox
    --cache-path "$project_root/.build/swiftpm-cache"
    --config-path "$project_root/.build/swiftpm-config"
    --security-path "$project_root/.build/swiftpm-security"
    -c release
)
sdk_path=${CMUX_COMPANION_SDK:-}
if [[ -z "$sdk_path" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    # Current CLT installations can expose a newer default SDK whose Swift
    # patch version does not match the compiler. Prefer the known-compatible
    # 15.4 SDK when it is available; callers can override this explicitly.
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
if [[ -n "$sdk_path" ]]; then
    if [[ ! -d "$sdk_path" ]]; then
        printf '%s\n' "package-app: SDK does not exist: $sdk_path" >&2
        exit 2
    fi
    machine_arch=$(uname -m)
    case "$machine_arch" in
        arm64|x86_64) ;;
        *)
            printf '%s\n' "package-app: unsupported build architecture: $machine_arch" >&2
            exit 2
            ;;
    esac
    swift_arguments+=(--sdk "$sdk_path" --triple "$machine_arch-apple-macosx${minimum_macos}")
fi

printf '%s\n' "Building release binaries..."
swift build "${swift_arguments[@]}"
bin_path=$(swift build "${swift_arguments[@]}" --show-bin-path)

for executable in CmuxCompanion cmux-set; do
    if [[ ! -x "$bin_path/$executable" ]]; then
        printf '%s\n' "package-app: missing release executable: $bin_path/$executable" >&2
        exit 1
    fi
done

temporary_bundle=$(mktemp -d "${TMPDIR:-/tmp}/CmuxCompanion.app.XXXXXX")
trap 'rm -rf "$temporary_bundle"' EXIT
contents="$temporary_bundle/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
mkdir -p "$macos_dir" "$resources_dir/scripts"

install -m 0755 "$bin_path/CmuxCompanion" "$macos_dir/CmuxCompanion"
install -m 0755 "$bin_path/cmux-set" "$macos_dir/cmux-set"
install -m 0755 "$script_dir/remote-hook-bridge.sh" "$resources_dir/scripts/remote-hook-bridge.sh"
install -m 0755 "$script_dir/install-remote-hooks.sh" "$resources_dir/scripts/install-remote-hooks.sh"
install -m 0755 "$script_dir/install-local.sh" "$resources_dir/scripts/install-local.sh"
install -m 0644 "$script_dir/shell-command-hook.zsh" "$resources_dir/scripts/shell-command-hook.zsh"

info_plist="$contents/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
plutil -insert CFBundleDisplayName -string CmuxCompanion "$info_plist"
plutil -insert CFBundleExecutable -string CmuxCompanion "$info_plist"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$info_plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -insert CFBundleName -string CmuxCompanion "$info_plist"
plutil -insert CFBundlePackageType -string APPL "$info_plist"
plutil -insert CFBundleShortVersionString -string "$marketing_version" "$info_plist"
plutil -insert CFBundleVersion -string "$build_version" "$info_plist"
plutil -insert CmuxCompanionUpdateChannel -string "$update_channel" "$info_plist"
plutil -insert LSMinimumSystemVersion -string "$minimum_macos" "$info_plist"
plutil -insert LSUIElement -bool true "$info_plist"
plutil -insert NSHighResolutionCapable -bool true "$info_plist"
plutil -insert UTExportedTypeDeclarations -json '[{"UTTypeConformsTo":["public.data"],"UTTypeDescription":"Cmux Companion surface drag token","UTTypeIdentifier":"dev.cmuxcompanion.surface-drag-token"},{"UTTypeConformsTo":["public.data"],"UTTypeDescription":"Cmux Companion set order drag token","UTTypeIdentifier":"dev.cmuxcompanion.set-order-drag-token"}]' "$info_plist"

# A locally built bundle can inherit Finder/iCloud quarantine from the project
# directory itself. That makes Gatekeeper present an "Apple cannot check it"
# dialog even though every executable was compiled from this checkout. Strip
# quarantine only from this newly-created temporary artifact before signing.
if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$temporary_bundle" 2>/dev/null || true
fi

if command -v codesign >/dev/null 2>&1 && [[ "${CMUX_COMPANION_SKIP_CODESIGN:-0}" != "1" ]]; then
    codesign --force --deep --sign - "$temporary_bundle"
    # Verify while the bundle is still outside Documents/File Provider. Some
    # providers immediately recreate an empty FinderInfo xattr after the move;
    # codesign then rejects that metadata even though the sealed files and the
    # signature have not changed.
    codesign --verify --deep --strict "$temporary_bundle"
fi

# The complete temporary bundle is built and optionally signed before the old
# generated artifact is replaced, keeping failed builds from destroying it.
if [[ -e "$app_bundle" ]]; then
    rm -rf "$app_bundle"
fi
mv "$temporary_bundle" "$app_bundle"
trap - EXIT

# Moving into a quarantined/synced parent can reattach the marker to the root
# directory. Removing that one generated-artifact attribute does not alter the
# app signature and prevents App Translocation on the next local launch.
if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$app_bundle" 2>/dev/null || true
    xattr -dr com.apple.FinderInfo "$app_bundle" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "$app_bundle" 2>/dev/null || true
fi
mkdir -p "$dist_dir/bin"
standalone_cli="$dist_dir/bin/cmux-set.tmp.$$"
install -m 0755 "$bin_path/cmux-set" "$standalone_cli"
mv -f "$standalone_cli" "$dist_dir/bin/cmux-set"

printf '%s\n' "Packaged: $app_bundle"
printf '%s\n' "Helper:   $dist_dir/bin/cmux-set"
