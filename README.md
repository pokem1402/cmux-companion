# Cmux Companion

Cmux Companion is a native macOS menu-bar app that groups cmux terminals into
logical worker/reviewer sets, tracks local and remote coding-agent lifecycle,
and surfaces transitions outside cmux without patching or re-signing cmux.

The repository builds three deliverables:

- `CmuxCompanion.app`: menu-bar UI, floating pet/HUD, notifications, and cmux jump actions.
- `cmux-set`: a terminal helper for manually linking the current cmux surface.
- `remote-hook-bridge.sh`: a telemetry bridge for agents running through `cmux ssh`.

## Status model

Members are tracked as `running`, `waiting`, `idle`, `ended`, `stale`,
`disconnected`, `error`, or `unknown`. Sets are evaluated by explicit groups:

- `all`: every member in the group must be running.
- `minActive(n)`: at least `n` members must be running.

A set does not alert until it is armed. Completing a turn does not implicitly
complete the whole set; the current generation must be completed explicitly.

## Requirements

- macOS 14 or newer.
- cmux 0.64.19 or newer installed in `/Applications`, or `cmux` on `PATH`.
- cmux Agent hooks installed for the agents you want to track.
- For an independently launched companion, cmux **Socket Control Mode** must be
  `Automation` (same macOS user) or `Password`. Do not use `allowAll` on a
  shared Mac.

If this setting is changed while cmux is already running, restart cmux once
after saving active work so the existing control socket adopts the new mode.

## Build

```bash
./scripts/package-app.sh
```

The packaged app and CLI are written to `dist/`. The build script accepts
`CMUX_COMPANION_SDK=/path/to/MacOSX.sdk` when the selected Command Line Tools
and default SDK are not compatible. Packaged builds use the `preview` update
channel by default; use `CMUX_COMPANION_UPDATE_CHANNEL=stable` to make a build
ignore GitHub prereleases. The only accepted channel values are `stable` and
`preview`.

To produce the two assets required by the in-app updater, set the release
version and monotonically increasing build number, then run:

```bash
CMUX_COMPANION_VERSION=0.1.4 \
CMUX_COMPANION_BUILD_NUMBER=5 \
./scripts/package-release.sh
```

The helper rebuilds the app, sanitizes metadata, creates the ZIP and SHA-256
sidecar under `dist/release/`, then extracts and verifies the result. For a tag
named `v0.1.4`, upload both assets without renaming them:

```text
CmuxCompanion-v0.1.4-macos-arm64.zip
CmuxCompanion-v0.1.4-macos-arm64.zip.sha256
```

These names are exact: the updater ignores a release if either asset is absent
or renamed.

## Run

If the repository lives in Documents/iCloud or another File Provider folder,
launching the bundle in-place can inherit quarantine/Finder metadata and make
Gatekeeper reject the local ad-hoc signature. Install the verified copy outside
the synced workspace instead:

```bash
./scripts/install-local.sh --launch
```

Use `--replace` when updating an existing local installation. The installer
keeps the previous copy beside it as a recoverable timestamped backup. If that
copy is running, the installer quits and relaunches it around the replacement
so two Companion processes cannot consume the same state concurrently.

Install the helper somewhere on `PATH`, or invoke it from `dist/bin/cmux-set`:

```bash
cmux-set join PR-142 --role worker --label main
cmux-set join PR-142 --role reviewer --label claude
cmux-set arm PR-142
cmux-set complete PR-142
```

The menu-bar UI can also create sets and link discovered surfaces without the
helper. Grab the `≡` handle on an unlinked terminal card and drop it onto a
set's `Worker`, `Reviewer`, or `Other` target; drop a cmux browser card onto
`PR`. Grab the same handle on a linked member to move it to another role,
existing group, or set while retaining its identity, lifecycle, remote state,
and last prompt. PR attachments can likewise move between `PR` targets. Drop
any linked member or PR on the fixed `그룹에서 내리기` target at the bottom to
remove only the Companion association—the cmux terminal or browser remains
open and returns to the unlinked tray when it is still live. The `연결` menus
remain available for keyboard and assistive-technology use.

Each set's `…` menu opens a 16-color quick palette and a native macOS custom
color picker. Custom colors are stored with the set as `#RRGGBB`, so they
survive restarts and remain compatible with existing saved data.

Terminal cards show the current surface workload as a small badge. Active cmux
sessions are normalized to `Codex`, `Claude`, or the original name for another
agent. A live terminal with an authoritative sessions snapshot and no active
agent is shown as `Shell`; the label intentionally does not guess Bash versus
zsh/fish because the public cmux tree does not expose that foreground process.
Remote hook-owned agents add a `Remote` suffix. If the sessions snapshot is
temporarily unavailable, Companion retains the last known agent or shows
`Unknown` instead of incorrectly switching the card to `Shell`.

## Updates

Starting with v0.1.1, Companion checks the GitHub Releases feed no more than
once every 24 hours and also provides a manual update check in the app. A
`preview` build considers prereleases as well as regular releases; a `stable`
build considers only regular releases. Draft releases are never offered.

Before offering an install, Companion downloads the macOS app ZIP and verifies
its bytes against both GitHub's release-asset digest and the published
`.sha256` sidecar. Installation always requires explicit user confirmation;
the app never silently replaces itself. These checks detect download
corruption and disagreement between release assets, but they do **not** prove
publisher authenticity if the GitHub repository or account is compromised.
Preview builds are ad-hoc signed and are not Apple Developer ID signed or
notarized, so Gatekeeper may still require Finder's **Open** action.

Self-replacement is attempted only when the current app is installed in a
location writable by the current user, such as `~/Applications`. If the app is
running from a read-only disk image, an unwritable `/Applications` directory,
or another location that cannot be safely replaced, Companion falls back to a
manual download/install flow. The existing v0.1.0 release has no updater, so
v0.1.1 must be downloaded and installed manually once; in-app checks work for
subsequent releases.

## Local agent tracking

Install cmux's supported hooks explicitly:

```bash
/Applications/cmux.app/Contents/Resources/bin/cmux hooks setup
```

Cmux Companion combines the reconnectable event stream with `tree`, `sessions`,
and `feed.list` snapshots. Agent prompts are read from Feed data where
available. A generic shell does not expose every physical key press through the
public cmux API. To opt into submitted zsh-command capture, source the provided
hook after making `cmux-set` available on `PATH`:

```zsh
source /absolute/path/to/cmux_extension/scripts/shell-command-hook.zsh
```

This records the complete submitted command, which can include credentials or
other sensitive arguments. Commands beginning with a space are skipped by
default; set `CMUX_COMPANION_CAPTURE_SHELL=0` to disable capture.

## Remote tracking

Use `cmux ssh`, which injects the cmux surface identity and provides an
authenticated reverse relay. Plain `ssh` can be used to copy the installer,
but it does not provide tracking by itself. From the Mac checkout, copy both
scripts to each remote host:

```bash
ssh host 'mkdir -p "$HOME/cmux-companion-hooks"'
scp scripts/remote-hook-bridge.sh scripts/install-remote-hooks.sh \
  host:~/cmux-companion-hooks/
```

Then enter the working shell through cmux and install as the normal remote
agent user (never with `sudo`):

```bash
cmux ssh host
cd ~/cmux-companion-hooks
chmod +x remote-hook-bridge.sh install-remote-hooks.sh
./install-remote-hooks.sh --install
```

Python 3.8 or newer and the `cmux` relay CLI must be available on the remote
host. The installer creates only managed files under `~/.local`, refuses
root/system/shared prefixes and any path that resolves outside the current
user's `HOME` (including symlink escapes), and does not overwrite an existing
Codex or Claude configuration.

Merge lifecycle handlers into the agent's existing configuration. For Codex,
each key lives under `hooks` in `~/.codex/hooks.json`; for example:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "$HOME/.local/bin/cmux-companion-remote-codex-hook --event SessionStart",
        "timeout": 5
      }]
    }]
  }
}
```

Repeat that entry with the matching `--event` value for
`UserPromptSubmit`, `Stop`, `PreToolUse`, `PostToolUse`,
`PermissionRequest`, `PreCompact`, `PostCompact`, `SubagentStart`, and
`SubagentStop`. Enable Codex's hooks feature and approve the command hooks when
Codex asks; do not replace unrelated existing hook entries.

If it is not already enabled, merge this into `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

For Claude Code, merge handlers under `hooks` in
`~/.claude/settings.json`. Claude entries include a matcher:

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "$HOME/.local/bin/cmux-companion-remote-claude-hook --event SessionStart",
        "timeout": 5
      }]
    }]
  }
}
```

Use the same pattern for `UserPromptSubmit`, `Stop`, `SessionEnd`,
`PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`,
`SubagentStart`, and `SubagentStop`. The installer prints these paths and event
lists after both dry runs and installs.

Remote permission/question events are deliberately forwarded as non-actionable
status telemetry. They show the member as waiting, but the user must approve or
answer in the original remote terminal. Delivery uses short, ordered foreground
attempts with a bounded retry; failures never break the agent hook and are
recorded without prompt contents in
`~/.local/state/cmux-companion/remote-hook-errors.log`.

Remote hooks are edge-triggered rather than a continuous process probe. A
`running` or `unknown` member therefore remains healthy through 15 minutes of
hook silence, becomes `stale` after that, and becomes `disconnected` after 60
minutes. Explicit `waiting`, `idle`, `ended`, and `error` states are preserved
until another real lifecycle hook changes them; transport age never overwrites
those outcomes.

For a one-shot connectivity check and verbose diagnosis:

```bash
printf '{}' | CMUX_COMPANION_HOOK_DEBUG=1 \
  ~/.local/bin/cmux-companion-remote-codex-hook --heartbeat
tail ~/.local/state/cmux-companion/remote-hook-errors.log
```

An agent-owned timer may send a heartbeat during unusually long operations; a
cadence below the 15-minute stale lease is sufficient. Stop the timer with the
agent and do not leave an unbounded detached loop behind. Plain `ssh` needs a
separately designed authenticated tunnel/helper and is not accepted by this
bridge.

## Data and privacy

State is stored locally under:

```text
~/Library/Application Support/CmuxCompanion/
├── sets.json
└── commands/
```

Last-prompt and optional shell-command previews may contain sensitive text.
Remote prompts cross the authenticated `cmux ssh` reverse relay and are then
stored on the Mac; the remote diagnostic log stores only operational failure
metadata. Prompt previews are enabled by default and can be disabled from the
Companion menu; lock-screen visibility follows the user's macOS notification
settings.

## Development

```bash
./scripts/test.sh
```

Tests use fixture JSON and temporary stores; they do not require a running cmux
instance.
