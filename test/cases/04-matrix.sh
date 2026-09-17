#!/usr/bin/env bash
#
# The environment matrix from TESTING.md: each condition must produce a clean
# result or a clear error, never a crash, a hang, or a silent no-op.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_container

S="${SNAPSHOT:?SNAPSHOT must point at the omarchy-snapshot script}"

# gh must never reach real credentials, even if some leak into the container.
export GH_CONFIG_DIR="$(mktemp -d)"
export GH_TOKEN="" GITHUB_TOKEN="" GH_NO_UPDATE_NOTIFIER=1

# A PATH containing everything the tool uses except one tool.
path_without() {
  local hidden=$1 dir b p
  dir=$(mktemp -d)
  for b in bash sh env git file find sed awk grep python3 mktemp stat date mkdir \
           mv rm cp chmod install basename dirname numfmt wc sort head tail cat \
           tr cut uniq diff truncate timeout pacman mise gh systemctl id tee; do
    [[ $b == "$hidden" ]] && continue
    p=$(command -v "$b" 2>/dev/null) || continue
    ln -sf "$p" "$dir/$b"
  done
  printf '%s' "$dir"
}

# run_case <seconds> <command...> - sets $out and returns the exit status,
# distinguishing a timeout (124) from a failure.
run_case() {
  local secs=$1; shift
  out=$(timeout "$secs" "$@" 2>&1 </dev/null)
}

section "missing prerequisites produce a clear error"

run_case 30 env PATH="$(path_without mise)" "$S" --dry-run; status=$?
assert_eq       "mise absent exits 1"   "$status" "1"
assert_contains "mise absent explains"  "$out" "mise is not installed"

# A mise without `dot` must be named as a version problem, not a missing binary.
old=$(mktemp -d)
cat > "$old/mise" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "2026.1.0 linux-x64 (2026-01-01)" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$old/mise"

run_case 30 env PATH="$old:$PATH" "$S" --dry-run; status=$?
assert_eq       "mise without 'dot' exits 1"  "$status" "1"
assert_contains "mise without 'dot' names the required version" "$out" "2026.9.2"

run_case 30 env PATH="$(path_without gh)" "$S" --remote owner/repo --dry-run; status=$?
assert_eq       "gh absent with --remote shorthand exits 1" "$status" "1"
assert_contains "gh absent suggests a full git URL"         "$out" "full git URL"

run_case 30 env PATH="$(path_without gh)" "$S" --remote https://example.invalid/r.git --dry-run
assert_eq "a full git URL does not need gh" "$?" "0"

section "an unauthenticated gh fails instead of hanging"

run_case 60 "$S" --remote owner/repo --dry-run; status=$?
if (( status == 124 )); then
  fail "dry run with --remote does not hang" "timed out after 60s"
else
  pass "dry run with --remote does not hang"
  assert_eq "dry run with --remote exits 0" "$status" "0"
fi

# A throwaway home: this is the live path, and it applies before it reaches
# the remote step.
scratch=$(mktemp -d)
run_case 90 env HOME="$scratch" "$S" --remote owner/repo -y; status=$?
if (( status == 124 )); then
  fail "an unauthenticated --remote does not hang" "timed out after 90s"
else
  pass "an unauthenticated --remote does not hang"
  assert_contains "it says what went wrong" "$out" "error:"
fi

section "optional pieces of the environment may be absent"

run_case 30 env PATH="$(path_without pacman)" "$S" --dry-run; status=$?
assert_eq           "no pacman: still exits 0"        "$status" "0"
assert_not_contains "no pacman: no package manifest"  "$out" "Package manifest"

mv "$HOME/.config/omarchy" "$HOME/.omarchy-hidden"
run_case 30 "$S" --dry-run; status=$?
mv "$HOME/.omarchy-hidden" "$HOME/.config/omarchy"
assert_eq           "no ~/.config/omarchy: exits 0"          "$status" "0"
assert_not_contains "no ~/.config/omarchy: no plugin section" "$out" "Classifying Omarchy plugins"

mv "$HOME/.local/bin" "$HOME/.bin-hidden"
run_case 30 "$S" --dry-run; status=$?
mv "$HOME/.bin-hidden" "$HOME/.local/bin"
assert_eq           "no ~/.local/bin: exits 0"      "$status" "0"
assert_not_contains "no ~/.local/bin: not scanned"  "$out" "Scanning ~/.local/bin"

section "a home with nothing in it"

empty=$(mktemp -d)
run_case 30 env HOME="$empty" "$S" --dry-run; status=$?
assert_eq       "no ~/.config at all: exits 0"     "$status" "0"
assert_contains "no ~/.config at all: still plans" "$out" "Plan"

binonly=$(mktemp -d)
mkdir -p "$binonly/.local/bin"
cp /usr/bin/true "$binonly/.local/bin/a-binary"
run_case 30 env HOME="$binonly" "$S" --dry-run; status=$?
assert_eq           "~/.local/bin of only binaries: exits 0" "$status" "0"
assert_contains     "~/.local/bin of only binaries: excluded" "$out" "excluding a-binary"
assert_not_contains "~/.local/bin of only binaries: not tracked" "$out" "    ~/.local/bin"

section "USER unset"
# Plugin classification compares against \$USER under `set -u`.
run_case 30 env -u USER "$S" --dry-run; status=$?
assert_eq "USER unset: does not crash" "$status" "0"

section "no terminal for the confirmation prompt"

run_case 30 "$S" --no-remote; status=$?
if (( status == 124 )); then
  fail "no tty: aborts instead of hanging" "timed out waiting on the prompt"
else
  pass "no tty: aborts instead of hanging"
  assert_contains "no tty: says it aborted" "$out" "aborted"
  assert "no tty: nothing was applied" \
    test ! -e "$HOME/.config/mise/conf.d/omarchy-snapshot.toml"
fi

report "04-matrix"
