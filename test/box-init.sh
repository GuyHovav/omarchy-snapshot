#!/bin/sh
# PID 1 for the test box.
#
# systemd needs to write its own cgroup subtree. Under --cgroupns=private Docker
# gives us our own namespace root but mounts it read-only unless the container is
# privileged - and CAP_SYS_ADMIN is enough to remount it rw. Doing that here is
# what lets the box run unprivileged, which in turn keeps the host's block
# devices (/dev/mapper/omarchy_root and friends) out of the container entirely.
mount -o remount,rw /sys/fs/cgroup 2>/dev/null || true

exec /usr/lib/systemd/systemd
