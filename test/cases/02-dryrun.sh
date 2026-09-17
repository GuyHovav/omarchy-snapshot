#!/usr/bin/env bash
#
# Invariants 3, 4, 5 and 7: the plan is correct, and producing it changes
# nothing on the machine.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

S="${SNAPSHOT:?SNAPSHOT must point at the omarchy-snapshot script}"
WORK=$(mktemp -d)

# Every path under $HOME with its type, size, mode and mtime.
snapshot_home() {
  find "$HOME" -xdev -printf '%y %s %m %T@ %P\n' 2>/dev/null | sort
}

snapshot_units() {
  systemctl --user list-unit-files --no-legend --no-pager 2>/dev/null | sort
}

snapshot_home  > "$WORK/home.before"
snapshot_units > "$WORK/units.before"

out=$("$S" --dry-run 2>&1); status=$?

snapshot_home  > "$WORK/home.after"
snapshot_units > "$WORK/units.after"

section "invariant 7: --dry-run changes nothing"

assert_eq "--dry-run exits 0" "$status" "0"

if diff -q "$WORK/home.before" "$WORK/home.after" >/dev/null; then
  pass "home directory is byte-for-byte unchanged"
else
  fail "home directory changed during --dry-run" "$(diff "$WORK/home.before" "$WORK/home.after")"
fi

if diff -q "$WORK/units.before" "$WORK/units.after" >/dev/null; then
  pass "no systemd user unit appeared"
else
  fail "systemd user units changed" "$(diff "$WORK/units.before" "$WORK/units.after")"
fi

assert "no restore manifest was written" \
  test ! -e "$HOME/.config/mise/conf.d/omarchy-snapshot.toml"
assert "no mise history state was created" \
  test ! -d "$HOME/.local/state/mise/history"
assert_not_contains "config.toml gained no [dotfiles] section" \
  "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" "[dotfiles]"

section "invariant 3: binaries and oversized files are excluded"

assert_contains "the 200 MiB binary is excluded" "$out" "excluding huge-binary"
assert_contains "a small binary is excluded on type" "$out" "excluding vendored-binary"
assert_not_contains "a text script is not excluded" "$out" "excluding my-script"
assert_contains "~/.local/bin is still tracked for its scripts" "$out" "~/.local/bin"
assert_contains "the scan reports 2 scripts kept" "$out" "2 script(s) tracked"
assert_contains "the scan reports 2 files dropped" "$out" "2 binary/large file(s) excluded"

section "invariant 4: plugin classification follows the naming convention"

assert_contains "<user>.mine is tracked as yours"  "$out" "${USER:-test}.mine -> tracked (yours)"
assert_contains "vendor.thing records its git URL" "$out" "vendor.thing -> reinstalled from https://github.com/vendor/thing.git"
assert_contains "vendor.orphan warns"              "$out" "plugin 'vendor.orphan' is third-party but has no git remote"
assert_contains "vendor.thing is in the reinstall plan" "$out" "~/.config/omarchy/plugins/vendor.thing <- https://github.com/vendor/thing.git"
assert_not_contains "vendor.orphan is not in the reinstall plan" "$out" "vendor.orphan <-"

section "invariant 5: application state is never suggested"

# Only the tail of the report, so a match elsewhere in the plan does not count.
suggestions=$(printf '%s\n' "$out" | sed -n '/small enough to be configuration/,$p')

assert_contains     "the report ran at all"         "$out" "small enough to be configuration"
assert_contains     "an unlisted config dir is suggested" "$suggestions" "fixture-tool"
assert_not_contains "BraveSoftware is not suggested"      "$suggestions" "BraveSoftware"
assert_not_contains "discord is not suggested"            "$suggestions" "discord"

section "the plan covers the expected configuration"

for p in hypr alacritty nvim btop "systemd/user" "gh/config.yml" "mise/config.toml"; do
  assert_contains "tracks ~/.config/$p" "$out" "~/.config/$p"
done
assert_contains "tracks ~/.bashrc"   "$out" "~/.bashrc"
assert_contains "tracks ~/.gitconfig" "$out" "~/.gitconfig"

rm -rf "$WORK"
report "02-dryrun"
