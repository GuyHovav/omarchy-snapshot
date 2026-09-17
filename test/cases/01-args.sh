#!/usr/bin/env bash
#
# Argument handling. These are regressions for bugs already found and fixed;
# the `--remote --dry-run` case is the one that previously ran live.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

S="${SNAPSHOT:?SNAPSHOT must point at the omarchy-snapshot script}"

section "rejects malformed options"

assert_exit "--max-binary-size abc"      1 "$S" --max-binary-size abc --dry-run
assert_exit "--max-binary-size 0"        1 "$S" --max-binary-size 0 --dry-run
assert_exit "--max-binary-size -5"       1 "$S" --max-binary-size -5 --dry-run
assert_exit "--max-binary-size (no value)" 1 "$S" --max-binary-size
assert_exit "--remote (no value)"        1 "$S" --remote
assert_exit "--remote x --no-remote"     1 "$S" --remote x --no-remote
assert_exit "--no-remote --remote x"     1 "$S" --no-remote --remote x
assert_exit "--bogus"                    1 "$S" --bogus

section "a flag is never swallowed as a value"

out=$("$S" --remote --dry-run 2>&1); status=$?
assert_eq        "--remote --dry-run exits 1"           "$status" "1"
assert_contains  "--remote --dry-run reports an error"  "$out" "error:"
assert_not_contains "--remote --dry-run does not start work" "$out" "Checking prerequisites"

out=$("$S" --max-binary-size --dry-run 2>&1); status=$?
assert_eq       "--max-binary-size --dry-run exits 1" "$status" "1"
assert_contains "--max-binary-size --dry-run errors"  "$out" "error:"

section "accepts well-formed options"

assert_exit "--help"    0 "$S" --help
assert_exit "--version" 0 "$S" -V

out=$("$S" --version 2>&1)
assert_contains "--version names the tool" "$out" "omarchy-snapshot"

out=$("$S" --help 2>&1)
assert_contains "--help documents --remote"          "$out" "--remote"
assert_contains "--help documents --max-binary-size" "$out" "--max-binary-size"

assert_exit "--max-binary-size 2048 --dry-run" 0 "$S" --max-binary-size 2048 --dry-run
assert_exit "--no-remote --dry-run"            0 "$S" --no-remote --dry-run
assert_exit "-n -y"                            0 "$S" -n -y

report "01-args"
