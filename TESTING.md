# Testing omarchy-snapshot

This document is for anyone — human or agent — verifying this tool. The README
describes what the tool is *meant* to do; this describes how to check whether it does,
and where it is known to be weak.

## Read this first: the tool modifies the host

Outside `--dry-run`, `omarchy-snapshot`:

- writes `~/.config/mise/conf.d/omarchy-snapshot.toml`
- adds `[dotfiles]` and `[history] exclude` entries to `~/.config/mise/config.toml`
  (mise writes these; the tool does not edit that file directly)
- installs and starts a **systemd user service** (`dev.mise.mise-history.service`)
- begins capturing file history into `~/.local/state/mise/history/`
- may **create a GitHub repository** and push to it
- may rewrite `credential.https://github.com.helper` in `~/.gitconfig`

**Do not run the non-dry path on a machine you care about.** Use a container or a
throwaway VM. There is currently no `--prefix` or sandbox flag; `OMARCHY_SNAPSHOT_CONFIG`
redirects only the generated manifest, not mise's own state.

To undo a run on a scratch machine:

```bash
systemctl --user disable --now dev.mise.mise-history.service
rm -f  ~/.config/mise/conf.d/omarchy-snapshot.toml
rm -rf ~/.local/state/mise/history
# then remove the [dotfiles] and [history] blocks from ~/.config/mise/config.toml
```

## The harness itself must stay boxed in

`test/run.sh` boots a container whose PID 1 is systemd. systemd manages whatever
cgroup tree it is shown, so the box has to get its own cgroup namespace. An
earlier version of the harness ran the box with `--cgroupns=host` and
`-v /sys/fs/cgroup:/sys/fs/cgroup:rw`; the container's systemd adopted the
*host's* units, tore down the Hyprland session, locked sddm out of tty1 and took
the machine down about two seconds after the first container started.

The rules that follow from that:

- the box runs `--cgroupns=private`, and the host cgroupfs is never bind-mounted
- the box is **not** `--privileged`. It gets `--cap-add SYS_ADMIN`, and
  `test/box-init.sh` (PID 1) remounts the private cgroup tree rw before exec'ing
  systemd. Docker only mounts that tree rw for privileged containers, and
  `--privileged` would also hand the box the host's `/dev` - including the root
  device-mapper nodes, which showed up as a live `dev-mapper-omarchy_root.device`
  unit inside the box while this was being fixed
- `start_container` compares `/proc/self/ns/cgroup` inside the box against the
  host's and refuses to proceed if they match
- console and getty units are masked in the image, so the box cannot race the
  host for tty1

## Status of the code

| Path | State |
|---|---|
| `--dry-run`, discovery, classification, plan output | Exercised on a live Omarchy machine |
| Argument parsing and validation | Exercised, including malformed input |
| Manifest generation (`[bootstrap.*]` TOML) | Generated and validated against `tomllib` |
| Full local apply path (`--no-remote -y`) | Exercised end-to-end by `test/run.sh` in a fresh container |
| Remote creation, `origin set`, publish, verify | **Only ever run by hand. Still the risk area.** |
| Restore (`mise bootstrap --adopt`) | Never tested from a snapshot produced by this script |

The local half is covered: `03-apply` runs the real apply path in a disposable box and
checks the history repository mise builds from it. The remote half is not - `04-matrix`
only proves that an absent or unauthenticated `gh` fails cleanly instead of hanging.
Nothing has yet restored a machine from a snapshot this script produced.

## Invariants worth asserting

These are the properties the tool exists to guarantee. Each should be a test.

1. **No credential material is ever published.** After a full run against a fixture home
   containing `~/.config/gh/hosts.yml`, `~/.ssh/id_ed25519`, a `*.pem`, and a file named
   `something-token.json`, none of them appear in the published repository or anywhere in
   its git history.
2. **Exclusions precede capture.** A secret must never be committed and later removed —
   it must never enter history at all. Check `git log --all --diff-filter=A` in the
   history repo for excluded paths, not just the working tree.
3. **Nothing exceeds the binary threshold.** With a 200 MiB binary in `~/.local/bin`, the
   published repo contains no file over `--max-binary-size`.
4. **Plugin classification follows the naming convention.** Given plugins
   `<user>.mine`, `vendor.thing` (with a git remote) and `vendor.orphan` (without):
   `<user>.mine` is tracked, `vendor.thing` is excluded *and* present in
   `[bootstrap.repos]`, `vendor.orphan` is excluded *and* produces a warning.
5. **Application state is never suggested.** A populated `~/.config/BraveSoftware` must
   not appear in the "small enough to be configuration" report.
6. **The generated manifest is valid TOML** and contains one entry per
   `pacman -Qqe` package.
7. **`--dry-run` changes nothing.** Snapshot the whole home directory before and after;
   the diff must be empty, and no systemd unit may appear.

## Environment matrix

Each of these should produce a clean result or a clear error, never a crash or a silent
no-op.

| Condition | Expected |
|---|---|
| mise absent | `error: mise is not installed` |
| mise older than 2026.9.2 (no `mise dot`) | error naming the required version |
| `pacman` absent (non-Arch) | runs, skips the package manifest |
| `~/.config/omarchy` absent (plain Arch) | runs, skips plugin classification |
| `~/.local/bin` absent | runs, tracks nothing from it |
| `~/.local/bin` present but all binaries | excluded, and the path is not tracked |
| `gh` absent with `--remote owner/repo` | error suggesting a full git URL |
| `gh` present but unauthenticated | clear failure, not a hang on a credential prompt |
| `--remote` naming a repo that already exists | reuses it, does not fail |
| Target repo non-empty / has foreign commits | should warn; **currently unverified** |
| Second run on a configured machine | idempotent: no duplicate excludes, manifest rewritten |
| No `~/.config` at all | should not crash |

## Argument handling

Regression cases for bugs already found and fixed:

| Input | Expected |
|---|---|
| `--max-binary-size abc` | error, exit 1 |
| `--max-binary-size 0` | error, exit 1 |
| `--max-binary-size` (no value) | error, exit 1 |
| `--remote` (no value) | error, exit 1 |
| `--remote --dry-run` | error — must **not** consume the flag as a value |
| `--remote x --no-remote` | error, mutually exclusive |
| `--bogus` | error, exit 1 |

The `--remote --dry-run` case matters most: before it was fixed, the flag was swallowed
as the repository name and the tool proceeded in live mode.

## Known weak points

- **No `--prefix`.** `test/run.sh` supplies the disposable machine, so the apply path can
  be tested safely, but the tool itself still has no way to redirect mise's config and
  state. `OMARCHY_SNAPSHOT_CONFIG` moves only the generated manifest. Testing outside a
  container is still unsafe, which is why `require_container` exists.
- **`confirm()` reads from `/dev/tty`.** Without a terminal it fails, which currently
  causes an abort. That is a safe default but an accidental one, not a designed one.
- **The verification step is a backstop, not a proof.** It scans for a handful of
  credential patterns in a shallow clone. It will not catch an unusual secret format, and
  it does not inspect history, only the tip.
- **`CONFIG_CANDIDATES` is a curated list.** It will silently miss configuration for tools
  nobody thought of. The "small enough to be configuration" report is the mitigation, and
  it is heuristic.
- **Ordering assumption.** The tool relies on `mise dot exclude` taking effect before
  `mise dot track` captures a baseline. If mise ever changes that ordering, secrets could
  be captured. Invariant 2 above is the test that would catch it.
- **The suite proves invariants, not correctness of the restore.** 112 assertions pass,
  but every one of them inspects the machine the snapshot was taken *from*. Nothing
  checks that the snapshot can rebuild a different machine.

## Suggested first session

1. Build a container with mise ≥ 2026.9.2 and a fixture home: a few config dirs, a fake
   large binary, planted credential files, and three plugin directories matching the
   classification cases.
2. Run `--dry-run` and check the plan against invariants 3, 4 and 5.
3. Run the full path with `--no-remote` and check invariants 1, 2, 6 and 7.
4. Only then attempt `--remote` against a scratch GitHub account, and finish by restoring
   the snapshot onto a second clean container with `mise bootstrap --adopt`. That restore
   is the end-to-end case nothing has yet proven.
