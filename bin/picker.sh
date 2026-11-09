#!/usr/bin/env bash
# picker.sh: runs inside the floating Rex pane that the fzf_url action opens.
# The action already read the scrollback, extracted the URLs, and wrote them
# to the file in $1. Enter opens the selection, ctrl-y copies it, and tab
# selects more than one. The pane closes when this script exits.
# Must stay compatible with macOS /bin/bash 3.2.
#
# Environment, set by init.lua from the setup() options:
#   FZF_URL_OPEN_CMD     command that opens a URL (default: open or xdg-open)
#   FZF_URL_COPY_CMD     command that copies stdin to the clipboard
#   FZF_URL_FZF_OPTIONS  extra fzf options
#   FZF_URL_SOURCE_BLOCK the pane that ran the action
#   FZF_URL_ROWS         the starting height of the pane, in rows
#   FZF_URL_LIST_ROWS    the rows of the URL list, with wrapped URLs
#   FZF_URL_CACHE        the file where bin/measure.lua saves window sizes
#   FZF_URL_MEASURE      what bin/measure.lua needs to know about this pane
set -u

# Rex doesn't give focus back to the pane that ran the action when a floating
# pane closes, so do it on every exit. Rex sets REX_BIN_DIR in its panes.
refocus() {
    [[ -n "${FZF_URL_SOURCE_BLOCK:-}" ]] &&
        "${REX_BIN_DIR:+$REX_BIN_DIR/}rex" focus "$FZF_URL_SOURCE_BLOCK" >/dev/null 2>&1
}
trap refocus EXIT

# No `set -e`: a pane that closes without a message is hard to debug.
# Failures print a message and pause so the user can read it.
fail() {
    printf 'fzf-url: %s\n' "$1" >&2
    sleep 2
    exit 1
}

command -v fzf >/dev/null 2>&1 || fail "fzf not found in PATH"

url_file="${1:-}"
[[ -n "$url_file" && -f "$url_file" ]] || fail "no URL list file"
urls=$(<"$url_file")
rm -f "$url_file"
[[ -z "$urls" ]] && exit 0

# Draw fzf from the top of the pane, as tall as its content: the rows of the
# URL list plus 4 rows for the prompt, the help text, and two border lines. There is
# no bottom padding row, as Rex pads the bottom of a floating pane. The pane
# can be one or two rows taller than that, and the extra rows are then at
# the bottom. Two extra rows can happen in the first popup in a window,
# before bin/measure.lua saves the size of the window.
# init.lua starts the terminal at the smallest size that the pane can get,
# and sets FZF_URL_ROWS to its height. Without it, the terminal starts at the
# default size of 80x24, and the app sets the size of the pane shortly after
# it opens. fzf draws in place with --height, so lines that it draws before
# the resize stay on the screen. So then wait for the resize, for at most
# half a second.
if [[ -z "${FZF_URL_ROWS:-}" ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
        [[ "$(stty size 2>/dev/null)" != "24 80" ]] && break
        sleep 0.02
    done
fi

# Count the URLs in bash when init.lua doesn't pass the rows of the list.
# This count doesn't know about wrapped URLs.
count=${FZF_URL_LIST_ROWS:-}
if [[ -z "$count" ]]; then
    set -f
    old_ifs=$IFS
    IFS=$'\n'
    lines=($urls)
    IFS=$old_ifs
    set +f
    count=${#lines[@]}
fi
height=$((count + 4))
# With more URLs than fit, fill the pane and scroll the list. fzf limits
# --height to the pane height, also after a resize. But the pane can get a
# row more than FZF_URL_ROWS, and fzf would then grow by a row while you
# watch. So use FZF_URL_ROWS as the height.
[[ -n "${FZF_URL_ROWS:-}" && "$height" -gt "$FZF_URL_ROWS" ]] && height=$FZF_URL_ROWS

# Save the size that the app gives this pane, so that the next popup in this
# window fits its content exactly. This runs in the background, so fzf starts
# at once. It doesn't change this pane. Rex sets REX_BLOCK in its panes.
if [[ -n "${FZF_URL_MEASURE:-}" && -n "${FZF_URL_CACHE:-}" && -n "${REX_BLOCK:-}" ]]; then
    "${REX_BIN_DIR:+$REX_BIN_DIR/}rex" do "${0%/*}/measure.lua" block="$REX_BLOCK" \
        cache="$FZF_URL_CACHE" spec="$FZF_URL_MEASURE" >/dev/null 2>&1 &
fi

# --no-border and --layout default override FZF_DEFAULT_OPTS: a border adds two
# rows and two columns that the pane size does not count, and hides the list.
# fzf options ported from junegunn/tmux-fzf-url's fzf-url.rb. --expect
# reports the pressed key (ctrl-y, or empty for Enter) on the first output
# line. The selections follow.
# $FZF_URL_FZF_OPTIONS is intentionally unquoted: word-splitting is the point.
# shellcheck disable=SC2086
selection=$(printf '%s\n' "$urls" | fzf \
    --multi --no-margin --no-padding --no-border --layout default --wrap \
    --expect ctrl-y --style default \
    --header 'Enter: Open URL / CTRL-Y: Copy to clipboard' \
    --header-border top --header-first \
    --highlight-line --info inline-right \
    --padding 0,1,0,1 \
    --height "$height" \
    ${FZF_URL_FZF_OPTIONS:-}) || exit 0

key=${selection%%$'\n'*}
chosen=
[[ "$selection" == *$'\n'* ]] && chosen=${selection#*$'\n'}
[[ -z "$chosen" ]] && exit 0

get_copy_cmd() {
    if [[ -n "${FZF_URL_COPY_CMD:-}" ]]; then echo "$FZF_URL_COPY_CMD"
    elif command -v pbcopy >/dev/null 2>&1; then echo "pbcopy"
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then echo "wl-copy"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then echo "xclip -selection clipboard"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then echo "xsel --clipboard --input"
    fi
}

# The pane closes when this script exits, so openers other than macOS
# `open` are detached with nohup to outlive it.
open_url() {
    if [[ -n "${FZF_URL_OPEN_CMD:-}" ]]; then nohup $FZF_URL_OPEN_CMD "$1" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "$1"
    elif command -v xdg-open >/dev/null 2>&1; then nohup xdg-open "$1" >/dev/null 2>&1 &
    elif [[ -n "${BROWSER:-}" ]]; then nohup "$BROWSER" "$1" >/dev/null 2>&1 &
    else fail "no opener found (open/xdg-open/\$BROWSER)"
    fi
}

if [[ "$key" == "ctrl-y" ]]; then
    cmd=$(get_copy_cmd)
    [[ -z "$cmd" ]] && fail "no clipboard tool found (pbcopy/wl-copy/xclip/xsel)"
    printf '%s' "$chosen" | $cmd
else
    while IFS= read -r url; do
        [[ -n "$url" ]] && open_url "$url"
    done <<< "$chosen"
    wait
fi
