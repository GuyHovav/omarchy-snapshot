# Disposable Arch box for testing omarchy-snapshot.
#
# The tool under test is bind-mounted at run time rather than copied in, so
# editing it does not cost a rebuild. Only the environment lives in this image.

FROM archlinux:base

RUN pacman -Syu --noconfirm --needed \
      git file coreutils findutils diffutils \
      python github-cli openssh sudo which \
 && pacman -Scc --noconfirm

# System-wide so root and the test user agree on the version. mise >= 2026.9.2
# is what provides `mise dot`.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Lingering is recorded by this file, so `systemctl --user` works for `test`
# as soon as systemd comes up - there is no login session in a container.
RUN useradd -m -u 1000 -s /bin/bash test \
 && install -d -m 0755 /var/lib/systemd/linger \
 && touch /var/lib/systemd/linger/test

# Units that cannot work, or are pointless, inside a container. The console and
# getty units matter for more than tidiness: if the box ever boots privileged it
# can see the host's /dev, and a getty racing the host for tty1 is what locks
# the display manager out of its seat.
RUN systemctl mask \
      systemd-firstboot.service \
      systemd-udevd.service \
      systemd-modules-load.service \
      systemd-journald-audit.socket \
      systemd-hwdb-update.service \
      systemd-vconsole-setup.service \
      systemd-ask-password-console.path \
      console-getty.service \
      getty@.service \
      getty.target

COPY box-init.sh /usr/local/sbin/box-init

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/local/sbin/box-init"]
