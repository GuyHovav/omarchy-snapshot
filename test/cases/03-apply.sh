#!/usr/bin/env bash
#
# The full apply path with --no-remote. Invariants 1, 2 and 6, plus the
# watcher, idempotence, and whether the generated manifest actually reaches
# the snapshot.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_container

TESTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
S="${SNAPSHOT:?SNAPSHOT must point at the omarchy-snapshot script}"
MANIFEST="$HOME/.config/mise/conf.d/omarchy-snapshot.toml"
MISE_CONFIG="$HOME/.config/mise/config.toml"

section "the apply path runs"

out=$("$S" --no-remote -y 2>&1); status=$?
printf '%s\n' "$out" | sed 's/^/    | /'

assert_eq "exits 0" "$status" "0"
assert_contains "registered exclusions" "$out" "exclusion(s) registered"
assert_contains "tracked paths"         "$out" "path(s) tracked"
assert_contains "wrote the manifest"    "$out" "wrote ~/.config/mise/conf.d/omarchy-snapshot.toml"

# Locate the history repository mise created. mise keeps a *bare* repo at
# history/repo.git, so probing only for a .git working-tree directory misses it
# entirely. --git-dir is given explicitly so the probe can never walk up out of
# $HOME and latch onto some unrelated repository.
is_git_dir() { git --git-dir="$1" rev-parse --git-dir >/dev/null 2>&1; }

HISTROOT="$HOME/.local/state/mise/history"
GITDIR=""
for cand in "$HISTROOT/repo.git" "$HISTROOT/.git" "$HISTROOT"; do
  is_git_dir "$cand" && { GITDIR=$cand; break; }
done
if [[ -z $GITDIR ]]; then
  while IFS= read -r cand; do
    is_git_dir "$cand" && { GITDIR=$cand; break; }
  done < <(find "$HOME/.local/state/mise" -maxdepth 3 -type d \
             \( -name '*.git' -o -name .git \) 2>/dev/null)
fi

if [[ -z $GITDIR ]]; then
  fail "mise created a history repository" "no git repository found under ~/.local/state/mise
$(find "$HOME/.local/state/mise" -maxdepth 3 2>/dev/null | head -30)"
  report "03-apply"
  exit 1
fi
pass "mise created a history repository at ${GITDIR/#$HOME/\~}"

git_hist() { git --git-dir="$GITDIR" "$@"; }

# Every path that ever entered history, not just what is in the working tree.
added=$(git_hist log --all --diff-filter=A --name-only --pretty=format: 2>/dev/null \
        | sed '/^$/d' | sort -u)
# Bare repo: read the committed tree, not an index that does not exist.
tree=$(git_hist ls-tree -r --name-only HEAD 2>/dev/null)

section "invariant 2: excluded paths never entered history"

for secret in hosts.yml server.pem copilot-token.json my-secret.conf \
              id_ed25519 .netrc huge-binary vendored-binary; do
  assert_not_contains "$secret was never committed" "$added" "$secret"
done

section "invariant 1: no credential material is published"

hits=$(git_hist grep -I -l -E \
        'ghp_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY|aws_secret_access_key|hunter2' \
        $(git_hist rev-list --all 2>/dev/null) -- 2>/dev/null)
if [[ -z $hits ]]; then
  pass "no credential pattern in any commit"
else
  fail "credential pattern found in history" "$hits"
fi

section "invariant 3: nothing oversized is published"

# No working tree to walk in a bare repo, so size the published blobs directly -
# which is the more honest check anyway: it catches anything ever committed.
big=$(git_hist rev-list --objects --all 2>/dev/null \
      | git_hist cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null \
      | awk '$1 == "blob" && $2 > 1048576 && NF > 2 { printf "%s (%d KiB)\n", $3, $2/1024 }')
if [[ -z $big ]]; then
  pass "no published file over 1 MiB"
else
  fail "oversized files published" "$big"
fi

section "the configuration that should be there, is"

for want in .config/hypr/hyprland.conf .bashrc .gitconfig .local/bin/my-script; do
  assert_contains "$want is tracked" "$tree" "$want"
done
assert_not_contains "noise: .bak files are not tracked" "$tree" "hyprland.conf.bak"
assert_not_contains "noise: logs are not tracked"       "$tree" "debug.log"

section "invariant 6: the restore manifest is valid and complete"

assert "the manifest exists" test -f "$MANIFEST"

facts=$(python3 "$TESTDIR/facts.py" manifest "$MANIFEST" 2>&1)
if (( $? == 0 )); then
  pass "the manifest is valid TOML"
  get() { printf '%s\n' "$facts" | sed -n "s/^$1=//p" | head -1; }

  assert_eq "declares the watcher service" "$(get service_builtin)" "history-watch"
  assert_eq "records one plugin repo"      "$(get repos_count)" "1"
  assert_contains "records vendor.thing's URL" "$facts" \
    "~/.config/omarchy/plugins/vendor.thing https://github.com/vendor/thing.git"
  assert_eq "every package entry is a pacman entry" "$(get packages_all_pacman)" "1"
  assert_eq "one entry per explicitly-installed package" \
    "$(get packages_count)" "$(pacman -Qqe 2>/dev/null | wc -l)"
else
  fail "the manifest is valid TOML" "$facts"
fi

section "the manifest reaches the snapshot"
# A manifest that is never published cannot drive `mise bootstrap --adopt` on a
# fresh machine. ~/.config/mise/conf.d is not in CONFIG_CANDIDATES.
if [[ $tree == *"conf.d/omarchy-snapshot.toml"* ]]; then
  pass "the generated manifest is itself tracked"
else
  fail "the generated manifest is itself tracked" \
    "the manifest is written to ~/.config/mise/conf.d/ but that path is not tracked,
so it is never published and a restore would not see [bootstrap.packages]."
fi

section "the watcher"

if systemctl --user is-system-running >/dev/null 2>&1 || [[ -S ${XDG_RUNTIME_DIR:-}/bus ]]; then
  unit=$(systemctl --user list-unit-files --no-legend --no-pager 2>/dev/null | grep -c mise-history)
  if (( unit > 0 )); then
    pass "the watcher unit was installed"
    state=$(systemctl --user is-active dev.mise.mise-history.service 2>&1)
    assert_eq "the watcher is active" "$state" "active"
  else
    fail "the watcher unit was installed" "$(systemctl --user list-unit-files --no-pager 2>&1 | tail -20)"
  fi
else
  skip "watcher checks" "no systemd user session in this container"
fi

section "a second run is idempotent"

cfacts=$(python3 "$TESTDIR/facts.py" config "$MISE_CONFIG" 2>&1)
before_excludes=$(printf '%s\n' "$cfacts" | sed -n 's/^exclude_count=//p')

out2=$("$S" --no-remote -y 2>&1); status2=$?
assert_eq "the second run exits 0" "$status2" "0"

cfacts=$(python3 "$TESTDIR/facts.py" config "$MISE_CONFIG" 2>&1)
if (( $? == 0 )); then
  count=$(printf '%s\n' "$cfacts" | sed -n 's/^exclude_count=//p')
  unique=$(printf '%s\n' "$cfacts" | sed -n 's/^exclude_unique=//p')
  assert_eq "exclusions are not duplicated" "$count" "$unique"
  assert_eq "the exclusion count did not grow" "$count" "$before_excludes"
else
  fail "config.toml is still valid TOML after two runs" "$cfacts"
fi

assert "the manifest was rewritten, not appended" \
  test "$(grep -c '^\[bootstrap.services.mise-history\]' "$MANIFEST")" = "1"

report "03-apply"
