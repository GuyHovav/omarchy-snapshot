#!/usr/bin/env bash
#
# Run the omarchy-snapshot test suite. Each case gets a fresh container, so a
# case that configures the machine cannot affect the next one.
#
#   ./test/run.sh                 # everything
#   ./test/run.sh 03-apply        # one case
#   ./test/run.sh --shell         # a throwaway box with the fixture applied
#
# The tool is bind-mounted read-only, so editing it needs no rebuild.

set -uo pipefail

cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
IMAGE=${IMAGE:-omarchy-snapshot-test}
DOCKER=${DOCKER:-docker}

ALL_CASES=(01-args 02-dryrun 03-apply 04-matrix 05-restore)

b=$'\033[1m'; g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; d=$'\033[2m'; z=$'\033[0m'
[[ -t 1 ]] || { b=''; g=''; r=''; y=''; d=''; z=''; }

SHELL_MODE=0
KEEP=0
cases=()
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=1 ;;
    --keep)  KEEP=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) cases+=("$arg") ;;
  esac
done
(( ${#cases[@]} == 0 )) && cases=("${ALL_CASES[@]}")

if ! $DOCKER info >/dev/null 2>&1; then
  printf '%serror:%s cannot reach the docker daemon.\n\n' "$r" "$z" >&2
  printf '  sudo systemctl start docker\n' >&2
  printf '  sudo usermod -aG docker "$USER"   # then start a new session\n' >&2
  exit 1
fi

printf '%s==> building %s%s\n' "$b" "$IMAGE" "$z"
$DOCKER build -q -t "$IMAGE" . || exit 1

HOST_CGROUP_NS=$(readlink /proc/self/ns/cgroup 2>/dev/null)

# The box runs systemd as PID 1, and systemd manages whatever cgroup tree it can
# see. It must therefore get its OWN cgroup namespace: under --cgroupns=host with
# the host cgroupfs bind-mounted rw, that systemd adopts the host's units, tears
# down the desktop session and takes the machine down with it. Never reintroduce
# either of those flags.
#
# Nor --privileged: that hands the box the host's /dev, including the root
# device-mapper nodes. CAP_SYS_ADMIN is all systemd needs, because box-init
# remounts the (private) cgroup tree rw for it.
# /tmp is mounted `exec`. Docker's --tmpfs defaults to noexec, and several cases
# build a fake `mise` or `gh` in a mktemp dir to stand in for a missing or too-old
# binary. On a noexec mount access(X_OK) fails, so bash's PATH search skips the
# fake and silently finds the real tool - the case then tests nothing and fails
# in a way that points at the tool rather than at the mount.
boot_box() {
  $DOCKER run -d --cgroupns=private \
    --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec \
    -v "$REPO":/opt/src:ro \
    "$IMAGE" 2>/dev/null
}

# Belt and braces: if the box can see our cgroup namespace, its systemd can drive
# our units. Nothing about this suite is worth that.
assert_cgroup_isolated() {
  local ns
  ns=$($DOCKER exec "$1" readlink /proc/self/ns/cgroup 2>/dev/null)
  [[ -n $ns && -n $HOST_CGROUP_NS && $ns == "$HOST_CGROUP_NS" ]] || return 0

  $DOCKER rm -f "$1" >/dev/null 2>&1
  printf '%serror:%s the box shares the host cgroup namespace - refusing to run.\n' "$r" "$z" >&2
  printf '       its systemd would manage host units. Check the run flags.\n' >&2
  return 1
}

# Start a box running systemd, so `systemctl --user` works for the watcher.
# Falls back to a plain container if systemd will not come up; the cases skip
# the watcher checks in that case.
start_container() {
  local cid i
  cid=$(boot_box)

  if [[ -n $cid ]]; then
    assert_cgroup_isolated "$cid" || return 1

    for i in $(seq 1 45); do
      if $DOCKER exec "$cid" test -d /run/user/1000 2>/dev/null; then
        printf '%s' "$cid"; return 0
      fi
      $DOCKER inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true || break
      sleep 1
    done
    $DOCKER rm -f "$cid" >/dev/null 2>&1
  fi

  printf '%s    systemd did not come up; falling back to a plain container%s\n' "$y" "$z" >&2
  $DOCKER run -d --rm --cgroupns=private \
    -v "$REPO":/opt/src:ro \
    --entrypoint sleep "$IMAGE" infinity 2>/dev/null
}

exec_flags=(-u test
  -e HOME=/home/test -e USER=test
  -e XDG_RUNTIME_DIR=/run/user/1000
  -e SNAPSHOT=/opt/src/omarchy-snapshot
  -e TERM="${TERM:-xterm}")
[[ -t 1 ]] && exec_flags+=(-t)

if (( SHELL_MODE )); then
  cid=$(start_container)
  [[ -z $cid ]] && { echo "could not start a container" >&2; exit 1; }
  $DOCKER exec "${exec_flags[@]}" "$cid" bash /opt/src/test/fixture.sh
  printf '%s==> fixture applied. The tool is at /opt/src/omarchy-snapshot%s\n' "$b" "$z"
  $DOCKER exec -i "${exec_flags[@]}" "$cid" bash -l
  (( KEEP )) || $DOCKER rm -f "$cid" >/dev/null
  exit 0
fi

failed=()
for c in "${cases[@]}"; do
  printf '\n%s==> %s%s\n' "$b" "$c" "$z"

  cid=$(start_container)
  if [[ -z $cid ]]; then
    printf '%s    could not start a container%s\n' "$r" "$z"
    failed+=("$c")
    continue
  fi

  $DOCKER exec "${exec_flags[@]}" "$cid" bash /opt/src/test/run-case.sh "$c"
  status=$?
  (( status == 0 )) || failed+=("$c")

  if (( KEEP )); then
    printf '%s    container kept: %s%s\n' "$d" "${cid:0:12}" "$z"
  else
    $DOCKER rm -f "$cid" >/dev/null 2>&1
  fi
done

printf '\n%s==================================%s\n' "$b" "$z"
if (( ${#failed[@]} == 0 )); then
  printf '%sall cases passed%s\n' "$g" "$z"
  exit 0
fi
printf '%sfailing cases:%s %s\n' "$r" "$z" "${failed[*]}"
exit 1
