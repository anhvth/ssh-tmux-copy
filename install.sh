#!/usr/bin/env bash
# =====================================================================
# ssh-tmux-copy Installer
# Installs ssh-tmux-copy utilities (local or remote setup)
# =====================================================================
set -euo pipefail

INSTALL_DIR="$HOME/.ssh-tmux-copy"
BIN_DIR="$INSTALL_DIR/bin"

# Setup colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# Embedded Files
write_copy_script() {
  cat << 'EOF' > "$BIN_DIR/copy"
#!/usr/bin/env bash
# copy — copies standard input to the local or remote clipboard.
# Works via local clipboard tools or OSC 52 escape sequences over SSH.
set -euo pipefail

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

# Mirror to a temporary file so clipwatch / clipsync can pick it up
SELECT_FILE="/tmp/tmux_copy_text_select"
if cp "$tmp" "$SELECT_FILE" 2>/dev/null; then
  chmod 600 "$SELECT_FILE" 2>/dev/null || true
fi

copy_osc52() {
  command -v base64 >/dev/null 2>&1 || return 1

  # Inside tmux, send to tmux's clipboard buffer (needs set-clipboard on)
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    if tmux load-buffer -w - < "$tmp" 2>/dev/null; then
      return 0
    fi
  fi

  # Direct TTY fallback
  local target=""
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    target="$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)"
  fi
  if [[ -z "$target" && -w /dev/tty ]]; then
    target="/dev/tty"
  fi
  [[ -n "$target" && -w "$target" ]] || return 1

  local encoded
  encoded="$(base64 < "$tmp" | tr -d '\r\n')"
  printf '\033]52;c;%s\a' "$encoded" > "$target"
}

case "${OSTYPE:-}" in
  darwin*)
    if command -v pbcopy >/dev/null 2>&1; then
      pbcopy < "$tmp"
      exit 0
    fi
    ;;
  cygwin*)
    if [[ -w /dev/clipboard ]]; then
      cat "$tmp" > /dev/clipboard
      exit 0
    fi
    ;;
esac

if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1 && wl-copy < "$tmp"; then
  exit 0
elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1 && xclip -in -selection clipboard < "$tmp"; then
  exit 0
elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1 && xsel --clipboard --input < "$tmp"; then
  exit 0
elif copy_osc52; then
  exit 0
else
  printf 'copy: no clipboard target reachable; selection saved to %s\n' "$SELECT_FILE" >&2
  exit 0
fi
EOF
  chmod +x "$BIN_DIR/copy"
}

write_clipwatch_script() {
  cat << 'EOF' > "$BIN_DIR/clipwatch"
#!/usr/bin/env bash
# clipwatch — auto-push every tmux copy to the LOCAL clipboard.
# Watches /tmp/tmux_copy_text_select and emits an OSC 52 escape to this terminal.
set -uo pipefail

FILE="/tmp/tmux_copy_text_select"
INTERVAL=0.2

b64() {
  base64 -w0 "$FILE" 2>/dev/null || base64 "$FILE" | tr -d '\n'
}

emit() {
  printf '\033]52;c;%s\a' "$(b64)"
}

mtime() {
  cksum "$FILE" 2>/dev/null || echo missing
}

echo "clipwatch: watching $FILE — every tmux copy now lands on this terminal's clipboard (Ctrl+C to stop)"
last="$(mtime)"
while :; do
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -e close_write -e moved_to -e create /tmp --include 'tmux_copy_text_select' 2>/dev/null \
      || sleep "$INTERVAL"
  else
    sleep "$INTERVAL"
  fi
  cur="$(mtime)"
  if [[ "$cur" != "$last" && "$cur" != missing ]]; then
    last="$cur"
    emit
    printf 'clipwatch: copied %s bytes at %s\n' "$(wc -c < "$FILE")" "$(date +%T)"
  fi
done
EOF
  chmod +x "$BIN_DIR/clipwatch"
}

write_clipsync_script() {
  cat << 'EOF' > "$BIN_DIR/clipsync"
#!/usr/bin/env bash
# clipsync — run on your LOCAL machine: sync tmux copies from a remote host
# straight into the local clipboard.
set -uo pipefail

host="${1:-}"
if [[ -z "$host" ]]; then
  echo "usage: clipsync <ssh-host>" >&2
  exit 2
fi

clip_in() {
  if command -v pbcopy >/dev/null 2>&1; then pbcopy
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then wl-copy
  elif command -v xclip >/dev/null 2>&1; then xclip -in -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input
  else
    echo "clipsync: no local clipboard tool (pbcopy/wl-copy/xclip/xsel)" >&2
    return 1
  fi
}

# fail fast if there's no clipboard tool before opening the connection
printf '' | clip_in || exit 1

echo "clipsync: watching /tmp/tmux_copy_text_select on $host — Ctrl+C to stop"

# shellcheck disable=SC2087
ssh -o ServerAliveInterval=30 -T "$host" bash -s <<'REMOTE' |
FILE=/tmp/tmux_copy_text_select
INTERVAL="${CLIPSYNC_REMOTE_POLL_INTERVAL:-1}"
b64() { base64 -w0 "$FILE" 2>/dev/null || base64 "$FILE" | tr -d '\n'; }
sum() { cksum "$FILE" 2>/dev/null || echo missing; }
last="$(sum)"   # skip whatever was copied before we connected
while :; do
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -e close_write -e moved_to -e create /tmp --include 'tmux_copy_text_select' 2>/dev/null \
      || sleep "$INTERVAL"
  else
    sleep "$INTERVAL"
  fi
  cur="$(sum)"
  if [ "$cur" != "$last" ] && [ "$cur" != missing ]; then
    last="$cur"
    b64
    echo
  fi
done
REMOTE
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s' "$line" | base64 -d 2>/dev/null | clip_in \
    && printf 'clipsync: copied %s bytes at %s\n' \
         "$(printf '%s' "$line" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" "$(date +%T)"
done

echo "clipsync: connection to $host closed" >&2
EOF
  chmod +x "$BIN_DIR/clipsync"
}

write_tmux_conf() {
  cat << 'EOF' > "$INSTALL_DIR/tmux-copy.conf"
# =====================================================================
# Tmux Copy Mode — setup for ssh-tmux-copy
# Every copy lands on the SYSTEM clipboard via ~/.ssh-tmux-copy/bin/copy
# =====================================================================

setw -g mode-keys vi

# Let tmux reach the outer terminal's clipboard via OSC 52
set -g set-clipboard on
set -ga terminal-overrides ',*:Ms=\E]52;c;%p2%s\7'

# Enter copy mode: Prefix+Escape or Prefix+[
bind Escape copy-mode
bind [ copy-mode

# Paste the last tmux buffer: Prefix+p  (Prefix+= picks from older buffers)
unbind p
bind p paste-buffer

# Keyboard selection (vim-style): v=select, V=line, Ctrl-v=block, y/Enter=copy
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi V send -X select-line
bind -T copy-mode-vi C-v send -X rectangle-toggle
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -T copy-mode-vi Escape send -X cancel

# Mouse: drag selects and copies on release, like a plain terminal
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"

# Double-click copies the word, triple-click copies the line — no prefix needed
bind -n DoubleClick1Pane select-pane \; copy-mode -M \; send -X select-word \; send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -n TripleClick1Pane select-pane \; copy-mode -M \; send -X select-line \; send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -T copy-mode-vi DoubleClick1Pane select-pane \; send -X select-word \; send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
bind -T copy-mode-vi TripleClick1Pane select-pane \; send -X select-line \; send -X copy-pipe-and-cancel "~/.ssh-tmux-copy/bin/copy"
EOF
}

write_ssh_wrapper() {
  cat << 'EOF' > "$INSTALL_DIR/ssh-tmux-copy.sh"
# =====================================================================
# ssh-tmux-copy Shell Integration
# Hook the local 'ssh' command to ensure clipsync is running.
# =====================================================================

CLIPSYNC_TMUX_SOCKET="${CLIPSYNC_TMUX_SOCKET:-tmux}"
CLIPSYNC_TMUX_SESSION="${CLIPSYNC_TMUX_SESSION:-tmux-sync-clipboard}"
CLIPSYNC_AUTO_START="${CLIPSYNC_AUTO_START:-0}"
CLIPSYNC_RESTART_COOLDOWN="${CLIPSYNC_RESTART_COOLDOWN:-60}"
SSH_DIAGNOSTIC_RETRY="${SSH_DIAGNOSTIC_RETRY:-0}"

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

    local state_dir key lock_dir stamp now last qhost cmd
    state_dir="${TMPDIR:-/tmp}/ssh-tmux-copy-${UID:-$(id -u)}"
    mkdir -p "$state_dir" 2>/dev/null || return 0
    key="$(printf '%s' "$host" | cksum | awk '{print $1}')"
    lock_dir="$state_dir/clipsync-$key.lock"
    stamp="$state_dir/clipsync-$key.last"

    if ! mkdir "$lock_dir" 2>/dev/null; then
        return 0
    fi

    now="$(date +%s)"
    last="$(cat "$stamp" 2>/dev/null || printf 0)"
    if (( now - last < CLIPSYNC_RESTART_COOLDOWN )); then
        rmdir "$lock_dir" 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "$now" > "$stamp" 2>/dev/null || true

    # Check again after taking the lock to avoid duplicate tmux windows.
    if tmux -L "$CLIPSYNC_TMUX_SOCKET" list-windows -t "$CLIPSYNC_TMUX_SESSION" \
            -F '#{window_name}' 2>/dev/null | grep -qx -- "$host"; then
        rmdir "$lock_dir" 2>/dev/null || true
        return 0
    fi

    qhost="$(printf '%q' "$host")"
    cmd="$HOME/.ssh-tmux-copy/bin/clipsync $qhost; echo 'clipsync exited'; sleep 10"
    if tmux -L "$CLIPSYNC_TMUX_SOCKET" has-session -t "$CLIPSYNC_TMUX_SESSION" 2>/dev/null; then
        tmux -L "$CLIPSYNC_TMUX_SOCKET" new-window -d -t "$CLIPSYNC_TMUX_SESSION" -n "$host" "$cmd"
    else
        tmux -L "$CLIPSYNC_TMUX_SOCKET" new-session -d -s "$CLIPSYNC_TMUX_SESSION" -n "$host" "$cmd"
    fi
    rmdir "$lock_dir" 2>/dev/null || true
}

ssh() {
    local host
    if [[ "$CLIPSYNC_AUTO_START" == 1 || "$CLIPSYNC_AUTO_START" == true || "$CLIPSYNC_AUTO_START" == yes ]]; then
        host="$(_clipsync_target "$@")" && clipsync-ensure "$host"
    fi
    command env -u LC_ALL -u LC_CTYPE ssh "$@"
    local rc=$?

    if (( rc == 255 )) && [[ "$SSH_DIAGNOSTIC_RETRY" == 1 || "$SSH_DIAGNOSTIC_RETRY" == true || "$SSH_DIAGNOSTIC_RETRY" == yes ]]; then
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

clipsync-start() {
    local host
    host="$(_clipsync_target "$@")" || {
        printf 'usage: clipsync-start <ssh-host>\n' >&2
        return 2
    }
    clipsync-ensure "$host"
}

clipsync-stop() {
    tmux -L "$CLIPSYNC_TMUX_SOCKET" kill-session -t "$CLIPSYNC_TMUX_SESSION" 2>/dev/null \
        && echo "clipsync: stopped" || echo "clipsync: not running"
}
EOF
}

install_local() {
  log_info "Starting Local (Client / Laptop) installation..."
  mkdir -p "$BIN_DIR"
  
  log_info "Writing local clipsync utility..."
  write_clipsync_script

  log_info "Writing shell integration script..."
  write_ssh_wrapper

  local rc_file=""
  if [[ "$SHELL" == */zsh ]]; then
    rc_file="$HOME/.zshrc"
  elif [[ "$SHELL" == */bash ]]; then
    rc_file="$HOME/.bashrc"
  fi

  log_success "Local utilities installed to $INSTALL_DIR/bin/"

  if [[ -n "$rc_file" && -f "$rc_file" ]]; then
    if grep -q "ssh-tmux-copy.sh" "$rc_file"; then
      log_info "Shell integration is already loaded in $rc_file."
    else
      log_info "Adding shell integration load line to $rc_file..."
      echo "" >> "$rc_file"
      echo "# Load ssh-tmux-copy shell wrapper" >> "$rc_file"
      echo "[ -f \"$INSTALL_DIR/ssh-tmux-copy.sh\" ] && source \"$INSTALL_DIR/ssh-tmux-copy.sh\"" >> "$rc_file"
      log_success "Shell integration appended to $rc_file."
      log_info "Run 'source $rc_file' to load it in your current terminal session."
    fi
  else
    log_warn "Could not auto-configure your shell configuration file."
    log_warn "Please add the following line manually to your ~/.zshrc or ~/.bashrc:"
    echo "  [ -f \"$INSTALL_DIR/ssh-tmux-copy.sh\" ] && source \"$INSTALL_DIR/ssh-tmux-copy.sh\""
  fi
}

install_remote() {
  log_info "Starting Remote (Server) installation..."
  mkdir -p "$BIN_DIR"

  log_info "Writing copy utility..."
  write_copy_script

  log_info "Writing clipwatch utility..."
  write_clipwatch_script

  log_info "Writing tmux-copy config..."
  write_tmux_conf

  local tmux_conf="$HOME/.tmux.conf"
  log_success "Remote utilities installed to $INSTALL_DIR/bin/"

  if [[ -f "$tmux_conf" ]]; then
    if grep -q "ssh-tmux-copy/tmux-copy.conf" "$tmux_conf"; then
      log_info "tmux config is already integrated in $tmux_conf."
    else
      log_info "Appending configuration source line to $tmux_conf..."
      echo "" >> "$tmux_conf"
      echo "# ssh-tmux-copy settings" >> "$tmux_conf"
      echo "source-file \"$INSTALL_DIR/tmux-copy.conf\"" >> "$tmux_conf"
      log_success "tmux integration appended to $tmux_conf."
    fi
  else
    log_info "Creating new $tmux_conf with copy integrations..."
    echo "source-file \"$INSTALL_DIR/tmux-copy.conf\"" > "$tmux_conf"
    log_success "Created and configured $tmux_conf."
  fi

  # Reload active tmux configuration if a tmux server is running
  if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
    log_info "Active tmux server detected. Reloading configuration..."
    if tmux source-file "$tmux_conf" 2>/dev/null; then
      log_success "tmux configuration reloaded successfully."
    else
      log_warn "Failed to reload tmux config automatically. Try running 'tmux source-file $tmux_conf' inside a tmux session."
    fi
  else
    log_info "No active tmux server running. Config will load next time tmux starts."
  fi
}

main() {
  local target=""
  
  # Check command line arguments first
  if [[ "${1:-}" == "--local" || "${1:-}" == "local" ]]; then
    target="local"
  elif [[ "${1:-}" == "--remote" || "${1:-}" == "remote" ]]; then
    target="remote"
  fi

  # If not specified, ask the user interactively
  if [[ -z "$target" ]]; then
    # Open /dev/tty if stdin is not a terminal (e.g. when curl is piped to bash)
    if [ ! -t 0 ]; then
      exec 3<&0
      exec 0</dev/tty
    fi

    echo "ssh-tmux-copy Installer"
    echo "======================="
    echo "Where are you installing this tool?"
    echo "  1) Local  (Client/Laptop - automatically triggers clipboard sync on ssh)"
    echo "  2) Remote (Server - registers tmux bindings and uses OSC 52)"
    read -p "Select option (1 or 2): " choice
    
    case "$choice" in
      1) target="local" ;;
      2) target="remote" ;;
      *) log_error "Invalid selection. Exiting."; exit 1 ;;
    esac

    if [ ! -t 0 ]; then
      exec 0<&3
    fi
  fi

  if [[ "$target" == "local" ]]; then
    install_local
  elif [[ "$target" == "remote" ]]; then
    install_remote
  fi
  
  log_success "All done!"
}

main "$@"
