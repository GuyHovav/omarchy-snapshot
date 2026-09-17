# shellcheck shell=bash
# Assertions shared by the test cases. Cases deliberately do not use `set -e`:
# a failing assertion records a failure and the case keeps going.

PASSES=0
FAILURES=0
SKIPS=0

if [[ -t 1 ]]; then
  _g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _d=$'\033[2m'; _b=$'\033[1m'; _0=$'\033[0m'
else
  _g=''; _r=''; _y=''; _d=''; _b=''; _0=''
fi

section() { printf '\n%s-- %s%s\n' "$_b" "$*" "$_0"; }

# Cases that exercise the live path reconfigure the machine they run on: mise
# tracking, a systemd user unit, a running watcher. Refuse to do that to a real
# home by accident.
require_container() {
  [[ -n ${OMS_TEST_ALLOW_HOST:-} ]] && return 0
  [[ -e /.dockerenv || -e /run/.containerenv ]] && return 0
  grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0

  printf '%serror:%s this case applies changes to the machine and will not run outside a container.\n' \
    "$_r" "$_0" >&2
  printf '       run it with test/run.sh, or set OMS_TEST_ALLOW_HOST=1 if you mean it.\n' >&2
  exit 2
}

pass() { PASSES=$((PASSES + 1)); printf '  %sPASS%s %s\n' "$_g" "$_0" "$1"; }
skip() { SKIPS=$((SKIPS + 1));   printf '  %sSKIP%s %s%s\n' "$_y" "$_0" "$1" "${2:+ - $2}"; }

# Detail is capped so that one runaway failure cannot bury the rest of the run.
# A truncated diff that does not say it was truncated is worse than no diff at
# all, though - it reads as the whole story and sends you after the wrong cause.
# So say how much was dropped, and offer the way to see it.
DETAIL_LINES=${OMS_TEST_DETAIL_LINES:-100}

fail() {
  FAILURES=$((FAILURES + 1))
  printf '  %sFAIL%s %s\n' "$_r" "$_0" "$1"
  [[ -n ${2:-} ]] || return 0

  local total
  total=$(printf '%s\n' "$2" | wc -l)

  if (( DETAIL_LINES > 0 && total > DETAIL_LINES )); then
    printf '%s\n' "$2" | head -n "$DETAIL_LINES" | sed 's/^/         /'
    printf '         %s... %d more line(s) - rerun with OMS_TEST_DETAIL_LINES=0 to see them all%s\n' \
      "$_d" "$((total - DETAIL_LINES))" "$_0"
  else
    printf '%s\n' "$2" | sed 's/^/         /'
  fi
}

# assert <description> <command...>
assert() {
  local desc=$1; shift
  local out status
  out=$("$@" 2>&1); status=$?
  (( status == 0 )) && pass "$desc" || fail "$desc" "$out"
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
  if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to find: $3"; fi
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
  if [[ $2 != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to find: $3"; fi
}

# assert_eq <description> <actual> <expected>
assert_eq() {
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: $3
  actual: $2"; fi
}

# assert_exit <description> <expected code> <command...>
assert_exit() {
  local desc=$1 want=$2; shift 2
  local out status
  out=$("$@" 2>&1); status=$?
  if (( status == want )); then
    pass "$desc"
  else
    fail "$desc" "exit $status, wanted $want
$out"
  fi
}

report() {
  printf '\n%s== %s: %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
    "$_b" "${1:-results}" "$_g" "$PASSES" "$_0" \
    "$_r" "$FAILURES" "$_0" "$_y" "$SKIPS" "$_0"
  (( FAILURES == 0 ))
}
