# omarchy-snapshot

Continuously snapshot an [Omarchy](https://omarchy.org/) (or plain Arch) machine's
configuration to a private git repository, so a fresh install can be restored with one
command.

It is a thin, opinionated setup layer over [mise](https://mise.jdx.dev)'s built-in dotfile
history. mise does the hard part — watching files, checkpointing, syncing. This script
decides *what* to track on an Omarchy box, and makes sure your credentials and binaries
never get into the repository in the first place.

```bash
./omarchy-snapshot --remote yourname/machine-setup
```

## The rule: manifest, not artifacts

Your config repo should hold what *rebuilds* the machine, not what a rebuild would
download. Think `package.json`, not `node_modules`.

| Tracked | Recorded as a manifest | Excluded outright |
|---|---|---|
| Hyprland, Omarchy shell, terminals, editors, `systemd/user` units, shell rc files, your own scripts | pacman packages, mise tools, third-party plugin git URLs | Binaries, vendored plugins, caches, anything credential-shaped |

On a typical machine this is a repo of one or two megabytes that can rebuild everything.

## What it does

1. **Excludes first, tracks second.** Credential patterns and noise are registered with
   mise *before* any file is captured, so a secret is never written into history and then
   removed — it is never captured at all.
2. **Classifies `~/.local/bin`.** Text scripts are tracked. Anything binary or over 1 MiB
   is excluded. (On the machine this was written for, that meant excluding a 204 MiB
   binary that would have hard-failed the push — GitHub rejects files over 100 MiB.)
3. **Classifies Omarchy plugins.** Omarchy names a plugin you cloned
   `<username>.<plugin>`, so yours are tracked. Third-party plugins are excluded, and
   those that are git checkouts get their URL written into `[bootstrap.repos]` so a
   restore clones them again. A third-party plugin with *no* remote is excluded with a
   warning, because nothing would record how to reinstall it.
4. **Writes a restore manifest** to `~/.config/mise/conf.d/omarchy-snapshot.toml`:
   every explicitly-installed pacman package, the plugin repos, and the watcher service.
   It owns that file entirely and rewrites it each run, so your own `config.toml` is never
   edited by this script.
5. **Starts the watcher** (`mise dot watch` as a systemd user service), which checkpoints
   changes and publishes them on its own.
6. **Verifies the result** by cloning the published repo back and checking for oversized
   files and credential patterns.

## Usage

```
omarchy-snapshot [OPTIONS]

  --remote <owner/repo|url>  Publish here. Created as private via gh if absent.
  --no-remote                Local history only.
  --max-binary-size <bytes>  Exclude non-text files above this. Default 1 MiB.
  -n, --dry-run              Show the plan, change nothing.
  -y, --yes                  Skip confirmation.
```

Start with `--dry-run`. It prints exactly what would be tracked and excluded, and touches
nothing.

## Restoring onto a fresh machine

```bash
mise bootstrap --adopt <owner/repo>
```

That pulls the configuration, installs the declared packages, clones the plugin repos,
restores the tracked files, and installs the declared tools.

## Do not push to the snapshot repo by hand

This is the one trap worth knowing, and it fails silently.

mise treats any commit it did not author as an *incoming change*. If that commit maps to
no tracked file — a `README.md` at the repo root, for instance — `mise dot pull` skips it,
but it stays counted as pending forever, and **pending incoming changes block
publication**. Your local checkpoints keep accumulating while the remote quietly goes
stale. Recovering means force-pushing the branch back to mise's last published commit.

So the repository has no root README, and anything you want in it has to arrive as a
tracked file.

## Status

The discovery, classification and `--dry-run` paths are exercised on a live Omarchy
machine. The **full apply path has not been run end-to-end on a clean system** — the
equivalent steps were done by hand and worked, but the script automating them is
unproven there. Start with `--dry-run`, and see [TESTING.md](TESTING.md) before running
it for real.

## Requirements

- `mise` 2026.9.2 or newer (for `mise dot`)
- `git`
- `gh`, only if you pass `--remote owner/repo` shorthand
- `pacman`, only for the package manifest

## Security notes

- Credential globs (`*token*`, `*secret*`, `*credential*`, `*.key`, `*.pem`, `id_rsa*`,
  `.netrc`, `auth.json`, `hosts.yml`) are excluded before tracking. mise applies its own
  secret globs too.
- Browser profiles and other application state are never suggested for tracking, even
  when they are small, because they hold cookies and session tokens.
- **Publication is automatic.** Anything you type into a tracked config file reaches the
  remote within seconds. Use a private repository, and never paste a token into a tracked
  file.
- The final verification step scans the published repo for credential patterns, but treat
  that as a backstop and not a guarantee.

## What it deliberately does not do

- **`/etc` is out of scope.** [`etckeeper`](https://wiki.archlinux.org/title/Etckeeper)
  handles it well with pacman hooks, but it should stay local-only: `/etc/shadow` is
  tracked by it, and pushing that anywhere would publish your password hashes.
- **It is not a backup.** It snapshots configuration, not documents, media, or databases.
- **It does not manage secrets.** If you need encrypted files in the snapshot, configure
  mise's `[history.encryption]` recipients *before* tracking them.

## License

MIT
