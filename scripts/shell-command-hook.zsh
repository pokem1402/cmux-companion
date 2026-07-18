# cmux-companion-shell-command-hook v1
#
# Source this file from ~/.zshrc to record submitted shell commands for the
# current cmux surface. It uses zsh's hook array and never replaces an existing
# `preexec` function.
#
#   source /path/to/shell-command-hook.zsh
#
# Privacy controls:
#   CMUX_COMPANION_CAPTURE_SHELL=0          disable capture
#   CMUX_COMPANION_CAPTURE_LEADING_SPACE=1 capture commands starting with space
#   CMUX_COMPANION_INPUT_MAX_LENGTH=4096    maximum saved characters
#   CMUX_COMPANION_CMUX_SET_BIN=/path/...   explicit helper executable

_cmux_companion_find_cmux_set() {
    if [[ -n ${CMUX_COMPANION_CMUX_SET_BIN:-} && -x ${CMUX_COMPANION_CMUX_SET_BIN} ]]; then
        print -r -- "${CMUX_COMPANION_CMUX_SET_BIN}"
        return 0
    fi
    if (( ${+commands[cmux-set]} )); then
        print -r -- "${commands[cmux-set]}"
        return 0
    fi
    if [[ -x /Applications/CmuxCompanion.app/Contents/MacOS/cmux-set ]]; then
        print -r -- /Applications/CmuxCompanion.app/Contents/MacOS/cmux-set
        return 0
    fi
    if [[ -x ${HOME}/Applications/CmuxCompanion.app/Contents/MacOS/cmux-set ]]; then
        print -r -- "${HOME}/Applications/CmuxCompanion.app/Contents/MacOS/cmux-set"
        return 0
    fi
    return 1
}

_cmux_companion_record_preexec() {
    setopt localoptions nobgnice
    [[ ${CMUX_COMPANION_CAPTURE_SHELL:-1} != 0 ]] || return 0
    [[ -n ${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}} ]] || return 0

    local submitted=${1:-}
    [[ -n $submitted ]] || return 0
    if [[ ${CMUX_COMPANION_CAPTURE_LEADING_SPACE:-0} != 1 && $submitted == ' '* ]]; then
        return 0
    fi

    local max_length=${CMUX_COMPANION_INPUT_MAX_LENGTH:-4096}
    if [[ $max_length != <1-> ]]; then
        max_length=4096
    fi
    if (( ${#submitted} > max_length )); then
        submitted=${submitted[1,max_length]}
    fi

    local helper
    helper=$(_cmux_companion_find_cmux_set) || return 0
    # The helper only performs one owner-local atomic file rename. Keep this
    # tiny write synchronous so two rapid commands cannot arrive in reverse
    # order and make the UI show the older command as the latest one.
    "$helper" input -- "$submitted" </dev/null >/dev/null 2>&1 || true
}

autoload -Uz add-zsh-hook
# Sourcing this file more than once remains idempotent and only replaces our
# own registration; all user and framework preexec hooks stay intact.
add-zsh-hook -d preexec _cmux_companion_record_preexec 2>/dev/null || true
add-zsh-hook preexec _cmux_companion_record_preexec
