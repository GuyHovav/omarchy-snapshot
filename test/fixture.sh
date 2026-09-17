#!/usr/bin/env bash
#
# Build a fixture home that exercises every classification the tool makes.
# Runs inside the container, as the test user. Idempotent.
#
# The credential files are planted *inside directories the tool tracks*, which
# is the only placement that actually tests the exclude-before-track ordering.

set -euo pipefail

H="$HOME"

mk() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-# fixture}" > "$1"
}

# ------------------------------------------------- configuration to track
mk "$H/.config/hypr/hyprland.conf" 'monitor=,preferred,auto,1
bind = SUPER, Return, exec, alacritty'
mk "$H/.config/alacritty/alacritty.toml" '[font]
size = 11'
mk "$H/.config/nvim/init.lua" 'vim.opt.number = true'
mk "$H/.config/systemd/user/fixture.service" '[Unit]
Description=fixture unit'
mk "$H/.config/btop/btop.conf" 'color_theme = "Default"'
mk "$H/.config/gh/config.yml" 'editor: nvim'
mk "$H/.config/mise/config.toml" '[tools]'
mk "$H/.config/omarchy/theme" 'tokyo-night'
mk "$H/.bashrc" 'export FIXTURE=1'
mk "$H/.bash_profile" 'source ~/.bashrc'
mk "$H/.gitconfig" '[user]
	name = Fixture User
	email = fixture@example.invalid'

# ------------------------------------------------- credentials (invariant 1)
# Every one of these sits under a path the tool tracks.
mk "$H/.config/gh/hosts.yml" 'github.com:
    oauth_token: ghp_FIXTUREaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mk "$H/.config/hypr/server.pem" '-----BEGIN RSA PRIVATE KEY-----
RklYVFVSRSBLRVkgTUFURVJJQUwK
-----END RSA PRIVATE KEY-----'
mk "$H/.config/nvim/copilot-token.json" '{"aws_secret_access_key": "FIXTUREaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
mk "$H/.config/btop/my-secret.conf" 'password = hunter2'
mk "$H/.netrc" 'machine example.invalid login fixture password hunter2'

mkdir -p "$H/.ssh"
mk "$H/.ssh/id_ed25519" '-----BEGIN OPENSSH PRIVATE KEY-----
RklYVFVSRSBLRVkgTUFURVJJQUwK
-----END OPENSSH PRIVATE KEY-----'
mk "$H/.ssh/id_ed25519.pub" 'ssh-ed25519 AAAAFIXTURE fixture@example.invalid'
chmod 700 "$H/.ssh"
chmod 600 "$H/.ssh/id_ed25519" "$H/.netrc"

# ------------------------------------------------- ~/.local/bin (invariant 3)
mkdir -p "$H/.local/bin"
printf '#!/usr/bin/env bash\necho hello\n'      > "$H/.local/bin/my-script"
printf '#!/usr/bin/env python3\nprint("hi")\n'  > "$H/.local/bin/my-tool"
chmod +x "$H/.local/bin/my-script" "$H/.local/bin/my-tool"
# Small but binary: excluded on type, not size.
cp /usr/bin/true "$H/.local/bin/vendored-binary"
# Large and binary: sparse, so it costs nothing on disk but reports 200 MiB.
truncate -s 200M "$H/.local/bin/huge-binary"
chmod +x "$H/.local/bin/huge-binary"

# ------------------------------------------------- plugins (invariant 4)
P="$H/.config/omarchy/plugins"

# Yours, by Omarchy's <user>.<plugin> naming convention.
mk "$P/${USER:-test}.mine/plugin.sh" '# my own plugin'

# Third-party with a remote: excluded, but recorded in [bootstrap.repos].
mk "$P/vendor.thing/plugin.sh" '# third-party plugin'
git init -q "$P/vendor.thing"
git -C "$P/vendor.thing" remote add origin https://github.com/vendor/thing.git

# Third-party with no remote: excluded, and must warn.
mk "$P/vendor.orphan/plugin.sh" '# third-party plugin, no remote'

# ------------------------------------------------- application state (inv. 5)
# Small enough to look like configuration, but full of session state.
for i in 1 2 3 4 5; do
  mk "$H/.config/BraveSoftware/Brave-Browser/Default/Cookies.$i" 'session state'
done
mk "$H/.config/discord/settings.json" '{"token":"fixture"}'

# A genuinely unlisted config dir, which *should* be suggested. Without this
# the invariant-5 check could pass simply because the report is broken.
mk "$H/.config/fixture-tool/config.yaml" 'setting: true'
mk "$H/.config/fixture-tool/rules.d/10-rule.conf" 'rule = 1'

# ------------------------------------------------- noise
mk "$H/.config/hypr/hyprland.conf.bak" 'old config'
mk "$H/.config/nvim/debug.log" 'noise'

echo "fixture ready in $H"
