#!/bin/bash
# Harness for .buildkite/scripts/ensure_gh.sh, the gh CLI download the production deploy step
# needs before it can create a GitHub Release.
#
# It exists because that download reddened main twice in a row: builds 28142 and 28143 each got
# a 504 from github.com's release CDN for the whole ~25s of the retry window the script had then
# (`--retry 5 --retry-delay 5`). ensure_gh returned non-zero, and create_github_release.sh --
# sourced by deploy_production.sh under `set -e` -- took the whole step down AFTER its deploy had
# already shipped, which marked the commit failed and reddened every PR cut from main.
#
# So the budget is tested as a PROPERTY (a window long enough to outlast a burst, not just one
# bad answer), and a failed download is pinned to still return non-zero so the caller keeps the
# decision to fall back rather than silently continuing with no CLI.
#
# Usage: ./ensure_gh_test.sh            run the cases
#        ./ensure_gh_test.sh --mutate   also prove each case FAILS against broken variants
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ensure_gh.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK" /tmp/gh.tar.gz "/tmp/gh_2.65.0_linux_amd64"' EXIT

mkdir -p "$WORK/bin" "$WORK/ghbin" "$WORK/installed"

# One tarball holding a stub gh, built once: the curl double copies it in on success, and a case
# can plant it in /tmp to stand in for a tarball an earlier attempt left behind. Same member
# layout the real download has, so the shipped tar/sudo/mv steps run for real.
make_gh_tarball() {
  mkdir -p "$WORK/gh_2.65.0_linux_amd64/bin"
  printf '#!/bin/bash\necho "gh 2.65.0 (stub)"\n' > "$WORK/gh_2.65.0_linux_amd64/bin/gh"
  chmod +x "$WORK/gh_2.65.0_linux_amd64/bin/gh"
  tar -czf "$1" -C "$WORK" gh_2.65.0_linux_amd64
}
make_gh_tarball "$WORK/gh-stub.tar.gz"

# --- test doubles ---------------------------------------------------------------------------
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
# Test double for curl: records its argv so the retry budget can be read back, then answers the
# gh CLI download with the tarball (or with the 504 the CDN actually gave).
printf '%s\n' "$*" >> "$CURL_LOG"
if [ "${CURL_MODE:-ok}" = "fail" ]; then
  echo "curl: (22) The requested URL returned error: 504" >&2
  exit 22
fi
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] || { echo "stub curl: no -o" >&2; exit 2; }
cp "$GH_TARBALL" "$out"
STUB

cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/bash
# Test double for sudo: drop the privilege wrapper and record what it was asked to run. No
# shift: the stub is invoked as `sudo mv src dst`, so $1 is already the command.
printf 'sudo %s\n' "$*" >> "$SUDO_LOG"
exec "$@"
STUB

cat > "$WORK/bin/mv" <<'STUB'
#!/bin/bash
# Test double for mv: the shipped script installs gh into /usr/local/bin, which a test must not
# touch, so every destination lands under $INSTALL_DIR instead. Source and target are logged
# untouched so the install can be asserted.
printf 'mv %s\n' "$*" >> "$MV_LOG"
dst="${!#}"
mkdir -p "$INSTALL_DIR/bin"
/bin/mv "${@:1:$#-1}" "$INSTALL_DIR/bin/$(basename "$dst")"
STUB

cat > "$WORK/ghbin/gh" <<'STUB'
#!/bin/bash
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/sudo" "$WORK/bin/mv" "$WORK/ghbin/gh"

# --- one run of the shipped ensure_gh ------------------------------------------------------
# Prints the exit status. Overrides arrive as KEY=VALUE arguments and are defaulted here:
# GH_PRESENT puts a gh on PATH (so the early return is exercised), CURL_MODE=fail answers the
# download with the 504 the CDN gave, STALE_TARBALL leaves one where an earlier attempt would.
# Not a `VAR=1 run_case` prefix, whose temporary assignment a later case can inherit.
run_case() {
  local gh_present=0 curl_mode=ok stale_tarball=0 o
  for o in "$@"; do
    case "$o" in
      GH_PRESENT=*) gh_present="${o#GH_PRESENT=}" ;;
      CURL_MODE=*) curl_mode="${o#CURL_MODE=}" ;;
      STALE_TARBALL=*) stale_tarball="${o#STALE_TARBALL=}" ;;
    esac
  done
  rm -rf "$WORK/installed/bin" /tmp/gh.tar.gz "/tmp/gh_2.65.0_linux_amd64"
  [ "$stale_tarball" = "1" ] && cp "$WORK/gh-stub.tar.gz" /tmp/gh.tar.gz
  : > "$WORK/curl.log"; : > "$WORK/sudo.log"; : > "$WORK/mv.log"
  local path="$WORK/bin:/usr/bin:/bin"
  [ "$gh_present" = "1" ] && path="$WORK/ghbin:$path"
  (
    cd "$WORK" || exit 1
    env PATH="$path" WORK="$WORK" GH_TARBALL="$WORK/gh-stub.tar.gz" CURL_LOG="$WORK/curl.log" \
      SUDO_LOG="$WORK/sudo.log" MV_LOG="$WORK/mv.log" INSTALL_DIR="$WORK/installed" \
      CURL_MODE="$curl_mode" bash -c "source '$SCRIPT'; ensure_gh"
  ) > "$WORK/out" 2>&1
  echo "$?"
}

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); [ -n "${QUIET:-}" ] || echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The window curl itself is asked to keep retrying inside.
curl_window() {
  local retry delay
  retry=$(sed -n 's/.*--retry \([0-9][0-9]*\).*/\1/p' "$WORK/curl.log" | head -1)
  delay=$(sed -n 's/.*--retry-delay \([0-9][0-9]*\).*/\1/p' "$WORK/curl.log" | head -1)
  [ -n "$retry" ] && [ -n "$delay" ] && echo $((retry * delay))
}

cases() {
  local st window maxtime

  # 1. An installed gh is used as-is: no download at all, so the common deploy path costs nothing.
  st=$(run_case GH_PRESENT=1)
  if [ "$st" = 0 ] && [ ! -s "$WORK/curl.log" ]; then pass "gh already on PATH -> no download"
  else fail "gh already on PATH -> status $st, curl log: $(cat "$WORK/curl.log")"; fi

  # 2. A download that works installs the CLI and returns 0.
  st=$(run_case)
  if [ "$st" = 0 ] && [ -x "$WORK/installed/bin/gh" ] && grep -q "/usr/local/bin/gh" "$WORK/mv.log"; then
    pass "download succeeds -> gh installed at /usr/local/bin/gh"
  else
    fail "download succeeds -> status $st, installed: $(ls "$WORK/installed/bin" 2>/dev/null), mv: $(cat "$WORK/mv.log")"
  fi

  # 3. A download that still fails returns non-zero, so the caller decides (create_github_release.sh
  #    falls back to the REST API instead of taking the deploy step down).
  st=$(run_case CURL_MODE=fail)
  if [ "$st" != 0 ]; then pass "download fails -> ensure_gh returns non-zero ($st)"
  else fail "download fails -> ensure_gh returned 0, the step would continue with no CLI"; fi

  # 3b. Even with a tarball an earlier attempt left in /tmp, a failed download must not pass for a
  #     success: the shipped steps return non-zero at the download, so nothing is installed from it.
  st=$(run_case CURL_MODE=fail STALE_TARBALL=1)
  if [ "$st" != 0 ] && [ ! -x "$WORK/installed/bin/gh" ]; then
    pass "a failed download with a stale /tmp tarball -> non-zero, nothing installed"
  else
    fail "stale tarball -> status $st, installed: $(ls "$WORK/installed/bin" 2>/dev/null)"
  fi

  # 4. The retry budget has to outlast a BURST. The 25s it used to have (5 x 5s) did not: both
  #    failing main builds got a 504 for the whole window. 2 minutes is the floor. Read back from
  #    a fresh download of this case, never from the log another case left behind.
  st=$(run_case)
  window=$(curl_window)
  maxtime=$(sed -n 's/.*--retry-max-time \([0-9][0-9]*\).*/\1/p' "$WORK/curl.log" | head -1)
  if [ "$st" = 0 ] && [ -n "$window" ] && [ "$window" -ge 120 ]; then
    pass "retry window ${window}s outlasts a burst"
  else
    fail "retry window -> '${window:-none}'s, needs >= 120 (curl log: $(cat "$WORK/curl.log"))"
  fi
  if [ -n "${maxtime:-}" ] && [ "$maxtime" -ge "${window:-0}" ]; then
    pass "--retry-max-time ${maxtime}s bounds the attempt"
  else
    fail "--retry-max-time -> '${maxtime:-none}'s, must be >= the retry window (${window:-none}s)"
  fi

  # 5. A refused connection has to be retried too, and the -f the rest of the step relies on
  #    (a 504 makes curl fail rather than save an error page as the tarball) must survive.
  if grep -q -- "--retry-connrefused" "$WORK/curl.log"; then pass "connection refusals are retried"
  else fail "connection refusals are retried -> missing --retry-connrefused"; fi
  if grep -q -- "-fsSL" "$WORK/curl.log"; then pass "download still fails on an HTTP error (-f)"
  else fail "download still fails on an HTTP error -> -f missing"; fi
}

echo "=== ensure_gh cases ==="
cases
echo
echo "PASS=$PASS FAIL=$FAIL"
BASE_FAIL=$FAIL

# ---------------------------------------------------------------------------
# Mutation testing: each mutation below MUST make the suite fail.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--mutate" ]; then
  echo
  echo "=== mutation testing (each mutant MUST be caught) ==="
  mutate() { # <desc> <perl-expr>
    local desc="$1" expr="$2"
    cp "$SCRIPT" "$WORK/orig.sh"
    perl -0pi -e "$expr" "$SCRIPT"
    if diff -q "$WORK/orig.sh" "$SCRIPT" >/dev/null; then
      echo "SKIP (mutation did not apply): $desc"; cp "$WORK/orig.sh" "$SCRIPT"; return
    fi
    PASS=0; FAIL=0; QUIET=1 cases
    if [ "$FAIL" -gt 0 ]; then echo "CAUGHT ($FAIL failing): $desc"
    else echo "ESCAPED -- suite is vacuous for: $desc"; ESCAPES=$((ESCAPES+1)); fi
    cp "$WORK/orig.sh" "$SCRIPT"
  }
  ESCAPES=0
  mutate "the budget is back to the 25s window that failed on main" \
    's/GH_CLI_RETRY=12/GH_CLI_RETRY=5/; s/GH_CLI_RETRY_DELAY=15/GH_CLI_RETRY_DELAY=5/'
  mutate "--retry-max-time no longer bounds the attempt" \
    's/GH_CLI_RETRY_MAX_TIME=300/GH_CLI_RETRY_MAX_TIME=1/'
  mutate "a failed download is swallowed by the library (a stale /tmp tarball stands in)" \
    's#-o /tmp/gh\.tar\.gz \|\| return 1#-o /tmp/gh.tar.gz#'
  mutate "an installed gh is downloaded over anyway" \
    's/  if command -v gh >\/dev\/null 2>&1; then/  if false; then/'
  mutate "connection refusals stop being retried" \
    's/--retry-connrefused/--no-retry-connrefused/'
  echo
  echo "MUTANTS_ESCAPED=$ESCAPES"
  [ "$ESCAPES" -eq 0 ] && [ "$BASE_FAIL" -eq 0 ] && echo "ALL GREEN: cases pass, every mutant caught"
fi

[ "$BASE_FAIL" -eq 0 ] || exit 1
