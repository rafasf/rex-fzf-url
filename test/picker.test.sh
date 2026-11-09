#!/usr/bin/env bash
# Tests for picker.sh. Must run under macOS /bin/bash 3.2.
#
# Fake fzf, open, pbcopy, xclip, sleep, stty, and rex programs go first in PATH.
# The rest of PATH is /bin only, so the real open and pbcopy in /usr/bin are
# not found. Each fake writes what it got to a log in $LOG.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/test/harness.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE=$TMP/bin
NOFZF=$TMP/nofzf
mkdir -p "$FAKE" "$NOFZF"

# fake <name> <body>: write a fake program into $FAKE.
fake() {
  printf '#!/bin/bash\n%s\n' "$2" >"$FAKE/$1"
  chmod +x "$FAKE/$1"
}

# fzf logs its arguments and input, then prints $FAKE_FZF_OUTPUT (with
# backslash escapes) and exits with $FAKE_FZF_EXIT.
fake fzf 'printf "%s\n" "$@" >"$LOG/fzf.args"; cat >"$LOG/fzf.in"; printf "%b" "${FAKE_FZF_OUTPUT:-}"; exit "${FAKE_FZF_EXIT:-0}"'
fake open 'printf "%s\n" "$*" >>"$LOG/open"'
fake myopen 'printf "%s\n" "$*" >>"$LOG/myopen"'
fake pbcopy 'printf "[%s]" "$*" >>"$LOG/pbcopy"; cat >>"$LOG/pbcopy"'
fake xclip 'printf "[%s]" "$*" >>"$LOG/xclip"; cat >>"$LOG/xclip"'
fake xdg-open 'printf "%s\n" "$*" >>"$LOG/xdg-open"'
fake browser 'printf "%s\n" "$*" >>"$LOG/browser"'
fake sleep 'printf "%s\n" "$*" >>"$LOG/sleep"'
# stty prints the pane size in $FAKE_STTY.
fake stty 'printf "%s\n" "${FAKE_STTY:-}"'
fake rex 'printf "%s\n" "$*" >>"$LOG/rex"'
ln -s /usr/bin/nohup "$FAKE/nohup"
for p in sleep rex; do ln -s "$FAKE/$p" "$NOFZF/$p"; done

# picker <file> [VAR=value ...]: run picker.sh on file, with a fresh log.
# Sets $status to its exit status, and $err to the lines of its stderr that
# start with "fzf-url:".
# Under kcov (test/run.sh --coverage), BASH_ENV turns on tracing in each
# bash, and bash 3.2 writes the trace to stderr. So keep BASH_ENV, and pass
# stderr on to kcov after the run.
picker() {
  local file=$1
  shift
  LOG=$(mktemp -d "$TMP/log.XXXX")
  env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$HOME" PATH="$FAKE:/bin" LOG="$LOG" \
    REX_BIN_DIR="$FAKE" FZF_URL_SOURCE_BLOCK=block:9 FZF_URL_ROWS=40 "$@" \
    /bin/bash "$DIR/bin/picker.sh" "$file" >/dev/null 2>"$TMP/stderr"
  status=$?
  err=$(grep '^fzf-url:' "$TMP/stderr")
  if [[ -n "${BASH_ENV:-}" ]]; then grep -v '^fzf-url:' "$TMP/stderr" >&2; fi
}

# run <urls> [VAR=value ...]: run picker.sh on a URL file that holds urls.
# Also sets $url_file to the URL file.
run() {
  local urls=$1
  shift
  url_file=$TMP/urls
  printf '%s\n' "$urls" >"$url_file"
  picker "$url_file" "$@"
}

# log <name>: print a log file, or nothing when it doesn't exist.
log() { [[ -f "$LOG/$1" ]] && cat "$LOG/$1"; }

two=$'https://a.example.com\nhttps://b.example.com'
three=$'https://a.example.com\nhttps://b.example.com\nhttps://c.example.com'

run "$two" FAKE_FZF_OUTPUT='\nhttps://b.example.com\n'
check_eq "enter opens the URL" "https://b.example.com" "$(log open)"
check_eq "enter exits 0" "0" "$status"
check_eq "fzf gets the URLs" "$two" "$(log fzf.in)"
check_eq "the URL file is removed" "no" "$([[ -e "$url_file" ]] && echo yes || echo no)"
check_eq "focus goes back to the source pane" "focus block:9" "$(log rex)"

run "$two" FAKE_FZF_OUTPUT='\nhttps://a.example.com\nhttps://b.example.com\n'
check_eq "enter opens each selected URL" "$two" "$(log open)"

run "$two" FAKE_FZF_OUTPUT='\nhttps://a.example.com\n' FZF_URL_OPEN_CMD='myopen --new'
check_eq "open_cmd is used, with its arguments" "--new https://a.example.com" "$(log myopen)"
check_eq "open_cmd replaces open" "" "$(log open)"

run "$two" FAKE_FZF_OUTPUT='ctrl-y\nhttps://a.example.com\nhttps://b.example.com\n'
check_eq "ctrl-y copies the selection" "[]$two" "$(log pbcopy)"
check_eq "ctrl-y opens nothing" "" "$(log open)"

run "$two" FAKE_FZF_OUTPUT='ctrl-y\nhttps://a.example.com\n' FZF_URL_COPY_CMD='xclip -in'
check_eq "copy_cmd is used, with its arguments" "[-in]https://a.example.com" "$(log xclip)"
check_eq "copy_cmd replaces pbcopy" "" "$(log pbcopy)"

# Without pbcopy, use xclip when DISPLAY is set.
mv "$FAKE/pbcopy" "$TMP/pbcopy"
run "$two" FAKE_FZF_OUTPUT='ctrl-y\nhttps://a.example.com\n' DISPLAY=:0
check_eq "xclip is the fallback with DISPLAY" "[-selection clipboard]https://a.example.com" "$(log xclip)"

run "$two" FAKE_FZF_OUTPUT='ctrl-y\nhttps://a.example.com\n'
check_eq "no clipboard tool fails" "1" "$status"
check_eq "no clipboard tool message" "fzf-url: no clipboard tool found (pbcopy/wl-copy/xclip/xsel)" "$err"
check_eq "focus goes back after a failure" "focus block:9" "$(log rex)"
mv "$TMP/pbcopy" "$FAKE/pbcopy"

run "$two" FAKE_FZF_EXIT=130
check_eq "escape exits 0" "0" "$status"
check_eq "escape opens nothing" "" "$(log open)"

run "$two" FAKE_FZF_OUTPUT='\n'
check_eq "enter with no match opens nothing" "" "$(log open)"

# The fzf height is the rows of the URL list plus 4, at most FZF_URL_ROWS.
height() { log fzf.args | grep -A1 -x -- --height | tail -1; }
run "$three" FZF_URL_LIST_ROWS=3
check_eq "height fits the URLs" "7" "$(height)"
run "$three" FZF_URL_LIST_ROWS=5
check_eq "height fits wrapped URLs" "9" "$(height)"
run "$three" FZF_URL_LIST_ROWS=3 FZF_URL_ROWS=6
check_eq "height is at most the pane rows" "6" "$(height)"
run "$three"
check_eq "height counts the URLs with no count given" "7" "$(height)"

run "$two" FZF_URL_FZF_OPTIONS='--exact --reverse'
check_eq "fzf_options are split into words" $'--exact\n--reverse' "$(log fzf.args | tail -2)"

run "$two" FZF_DEFAULT_OPTS='--border --layout=reverse'
check_eq "no border, whatever FZF_DEFAULT_OPTS says" "--no-border" "$(log fzf.args | grep -x -- --no-border)"
check_eq "default layout, whatever FZF_DEFAULT_OPTS says" "default" "$(log fzf.args | grep -x -A1 -- --layout | tail -1)"

# Without open, use xdg-open, then $BROWSER.
mv "$FAKE/open" "$TMP/open"
run "$two" FAKE_FZF_OUTPUT='\nhttps://a.example.com\n'
check_eq "xdg-open is the fallback" "https://a.example.com" "$(log xdg-open)"
mv "$FAKE/xdg-open" "$TMP/xdg-open"
run "$two" FAKE_FZF_OUTPUT='\nhttps://a.example.com\n' BROWSER=browser
check_eq "\$BROWSER is the last fallback" "https://a.example.com" "$(log browser)"
run "$two" FAKE_FZF_OUTPUT='\nhttps://a.example.com\n'
check_eq "no opener fails" "1" "$status"
check_eq "no opener message" 'fzf-url: no opener found (open/xdg-open/$BROWSER)' "$err"
mv "$TMP/open" "$TMP/xdg-open" "$FAKE/"

# With no starting size, wait while the pane is still 80x24, for at most
# 25 tries.
run "$two" FZF_URL_ROWS= FAKE_STTY="24 80"
check_eq "no starting size: waits for the resize" "25" "$(log sleep | wc -l | tr -d ' ')"
run "$two" FZF_URL_ROWS= FAKE_STTY="30 100"
check_eq "no starting size: no wait after the resize" "" "$(log sleep)"

# With a measure spec, start bin/measure.lua in the background.
run "$two" REX_BLOCK=block:7 FZF_URL_CACHE=/tmp/cache FZF_URL_MEASURE="window:1 k 0.5 0.4"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '^do ' "$LOG/rex" 2>/dev/null && break; /bin/sleep 0.1; done
check_eq "starts measure.lua" \
  "do $DIR/bin/measure.lua block=block:7 cache=/tmp/cache spec=window:1 k 0.5 0.4" "$(grep '^do ' "$LOG/rex")"
run "$two"
check_eq "no measure spec, no measure.lua" "" "$(grep '^do ' "$LOG/rex")"

run "$two" PATH="$NOFZF:/bin"
check_eq "no fzf fails" "1" "$status"
check_eq "no fzf message" "fzf-url: fzf not found in PATH" "$err"

picker "$TMP/none"
check_eq "a missing URL file fails" "1" "$status"
check_eq "a missing URL file message" "fzf-url: no URL list file" "$err"

finish
