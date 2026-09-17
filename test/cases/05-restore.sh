#!/usr/bin/env bash
#
# The round trip: publish a snapshot, then rebuild a machine from it.
#
# `mise bootstrap --adopt` accepts a full git URL, not just an owner/repo
# shorthand, so a local bare repository can stand in for the remote. Nothing
# here needs network access, GitHub, or credentials.
#
# This case wipes $HOME, so it depends on getting a container to itself.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_container

S="${SNAPSHOT:?SNAPSHOT must point at the omarchy-snapshot script}"
REMOTE=/tmp/snapshot-remote.git
ORIG=/tmp/orig

section "publishing to a bare repository"

# Deliberately left with git's default HEAD (master) while mise publishes to its
# own branch. That mismatch used to make verification clone an empty tree and
# report an all-clear having examined nothing.
git init -q --bare "$REMOTE"

out=$("$S" --remote "file://$REMOTE" -y 2>&1); status=$?
assert_eq "exits 0" "$status" "0"
assert_contains "verification counted the published files" "$out" "file(s) published"
assert_not_contains "verification did not pass on an empty clone" "$out" "0 file(s) published"
assert_not_contains "the snapshot is not reported empty" "$out" "the snapshot is empty"

published=$(git --git-dir="$REMOTE" ls-tree -r --name-only refs/heads/main 2>/dev/null)
assert_contains "the remote really holds the config" "$published" "home/.bashrc"
assert_contains "the remote holds the restore manifest" \
  "$published" "conf.d/omarchy-snapshot.toml"

section "invariant 1 and 2 hold on the wire, not just locally"

for secret in .netrc id_ed25519 hosts.yml server.pem copilot-token.json huge-binary; do
  assert_not_contains "$secret never reached the remote" "$published" "$secret"
done

section "restoring onto an empty machine"

# Keep only what the comparison needs: copying all of $HOME would drag the
# fixture's 200 MiB binary through tmpfs for nothing.
COMPARE=(.bashrc .gitconfig .config/hypr/hyprland.conf .local/bin/my-script
         .config/mise/conf.d/omarchy-snapshot.toml)
for f in "${COMPARE[@]}"; do
  mkdir -p "$ORIG/$(dirname "$f")"
  cp -a "$HOME/$f" "$ORIG/$f" 2>/dev/null
done

# The watcher captures edits as they happen; emptying $HOME underneath it would
# race with the restore.
systemctl --user stop dev.mise.mise-history.service >/dev/null 2>&1

find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
assert_eq "the home is empty before restoring" "$(ls -A "$HOME" | wc -l)" "0"

rout=$(mise bootstrap --adopt "file://$REMOTE" -y --only dotfiles 2>&1); rstatus=$?
assert_eq       "the restore exits 0"     "$rstatus" "0"
assert_contains "the restore wrote files" "$rout" "file(s) from file://$REMOTE"

section "what came back is what went in"

for f in "${COMPARE[@]}"; do
  if [[ ! -e $HOME/$f ]]; then
    fail "$f was restored" "missing from the rebuilt home"
  elif diff -q "$ORIG/$f" "$HOME/$f" >/dev/null 2>&1; then
    pass "$f was restored byte-for-byte"
  else
    fail "$f was restored byte-for-byte" "$(diff "$ORIG/$f" "$HOME/$f" 2>&1)"
  fi
done

section "secrets stayed out of the rebuilt machine"

for f in .netrc .ssh/id_ed25519 .config/hypr/hosts.yml .local/bin/huge-binary; do
  assert "$f is absent after restore" test ! -e "$HOME/$f"
done

section "the restored manifest can actually drive a bootstrap"
# A restore that returns the dotfiles but not the manifest leaves the machine
# with no packages, no plugin repos and no watcher - and looks like it worked.

assert "the manifest came back" test -f "$HOME/.config/mise/conf.d/omarchy-snapshot.toml"

plan=$(mise bootstrap plan 2>&1)
assert_contains "the plan lists pacman packages" "$plan" "package:pacman:"
assert_contains "the plan declares the watcher service" "$plan" "mise-history"
assert_contains "the plan sources them from the manifest" "$plan" "omarchy-snapshot.toml"

report "05-restore"
