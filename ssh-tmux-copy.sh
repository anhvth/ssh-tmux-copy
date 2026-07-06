# =====================================================================
# ssh-tmux-copy Shell Integration
# Hook the local 'ssh' command to ensure clipsync is running.
# =====================================================================

CLIPSYNC_TMUX_SOCKET="${CLIPSYNC_TMUX_SOCKET:-tmux}"
CLIPSYNC_TMUX_SESSION="${CLIPSYNC_TMUX_SESSION:-tmux-sync-clipboard}"

# First non-option arg = ssh destination (skips option flags that take a value)
_clipsync_target() {
    local skip_next=0 a
    for a in "$@"; do
        if (( skip_next )); then skip_next=0; continue; fi
        case "$a" in
            -[BbcDEeFIiJLlmOopQRSWw]) skip_next=1 ;;
            -*) ;;
            *) printf '%s\n' "$a"; return 0 ;;
        esac
    done
    return 1
}

clipsync-ensure() {
    local host="$1"
    [[ -n "$host" ]] || return 0
    [[ -z "${SSH_CONNECTION:-}" ]] || return 0   # only from the local machine
    command -v tmux >/dev/null 2>&1 || return 0
    [[ -x "$HOME/.ssh-tmux-copy/bin/clipsync" ]] || return 0
    
    # local clipboard tool required, otherwise clipsync can't do anything
    command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 \
        || command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1 || return 0

    # already running for this host?
    if tmux -L "$CLIPSYNC_TMUX_SOCKET" list-windows -t "$CLIPSYNC_TMUX_SESSION" \
            -F '#{window_name}' 2>/dev/null | grep -qx -- "$host"; then
        return 0
    fi
    local cmd="$HOME/.ssh-tmux-copy/bin/clipsync '$host'; echo 'clipsync exited'; sleep 10"
    if tmux -L "$CLIPSYNC_TMUX_SOCKET" has-session -t "$CLIPSYNC_TMUX_SESSION" 2>/dev/null; then
        tmux -L "$CLIPSYNC_TMUX_SOCKET" new-window -d -t "$CLIPSYNC_TMUX_SESSION" -n "$host" "$cmd"
    else
        tmux -L "$CLIPSYNC_TMUX_SOCKET" new-session -d -s "$CLIPSYNC_TMUX_SESSION" -n "$host" "$cmd"
    fi
}

ssh() {
    local host
    host="$(_clipsync_target "$@")" && clipsync-ensure "$host"
    command env -u LC_ALL -u LC_CTYPE ssh "$@"
    local rc=$?

    if (( rc == 255 )); then
        local arg
        for arg in "$@"; do
            case "$arg" in
                -v|-vv|-vvv|-vvvv|-*v*)
                    return "$rc"
                    ;;
            esac
        done

        printf 'ssh failed with exit code 255; retrying once with -vvv diagnostics...\n' >&2
        command env -u LC_ALL -u LC_CTYPE ssh -vvv "$@"
        return $?
    fi

    return "$rc"
}

clipsync-status() {
    tmux -L "$CLIPSYNC_TMUX_SOCKET" list-windows -t "$CLIPSYNC_TMUX_SESSION" \
        -F 'clipsync -> #{window_name}' 2>/dev/null || echo "clipsync: not running"
}

clipsync-stop() {
    tmux -L "$CLIPSYNC_TMUX_SOCKET" kill-session -t "$CLIPSYNC_TMUX_SESSION" 2>/dev/null \
        && echo "clipsync: stopped" || echo "clipsync: not running"
}
