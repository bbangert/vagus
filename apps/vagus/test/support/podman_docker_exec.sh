#!/bin/sh
# A `podman` for the opt-in :podman suite on a dev machine: runs the real
# podman inside a container on the host's Docker. Forwards the profile's Go
# env and the value of every value-less `--env NAME`, as the BEAM-side
# runner sets them. CONTAINERS_CONF_OVERRIDE is not forwarded: its path
# exists only on the BEAM side. VAGUS_PODMAN_RUN (set by test_helper.exs)
# gives each suite run a store of its own, so overlapping runs never see
# each other's containers or names.
c=${VAGUS_PODMAN_CONTAINER:-vagus-podman-fixtures}

envs=""
for name in GOMAXPROCS GOMEMLIMIT GOGC; do
  eval "isset=\${$name+x}"
  [ -n "$isset" ] && envs="$envs -e $name"
done

prev=""
sub=""
follow=""
for a in "$@"; do
  if [ "$prev" = "--env" ]; then
    case "$a" in *=*) ;; *) envs="$envs -e $a" ;; esac
  fi
  case "$a" in --log-level=*|--transient-store) ;; *) [ -z "$sub" ] && sub=$a ;; esac
  if [ "$sub" = logs ]; then case "$a" in -f|--follow) follow=1 ;; esac; fi
  prev=$a
done

store=""
if [ -n "$VAGUS_PODMAN_RUN" ]; then
  case "$VAGUS_PODMAN_RUN" in
    *[!A-Za-z0-9_.-]*) echo "Error: wrapper: bad VAGUS_PODMAN_RUN" >&2; exit 125 ;;
  esac
  store="--root /var/lib/vagus-test/$VAGUS_PODMAN_RUN --runroot /run/vagus-test/$VAGUS_PODMAN_RUN"
fi

# These stream until stopped, so there is no exit to wait for; the suite
# runs none of them (log follow and events read podman's files instead).
if [ "$sub" = events ] || [ "$sub" = attach ] || [ -n "$follow" ]; then
  # shellcheck disable=SC2086
  exec docker exec $envs "$c" podman $store "$@"
fi

# `docker exec` can return before podman exits, losing output and status,
# so podman runs detached, to files inside the container that are polled.
id="/tmp/vw.$$.$(date +%s%N)"

# Cmd's stderr-only capture points stdout at /dev/null; then only stderr
# may come back, as with muontrap running podman itself.
if [ "$(readlink "/proc/$$/fd/1")" = /dev/null ]; then
  quiet=1
  # shellcheck disable=SC2016
  redir='>/dev/null 2>"$0.out"'
else
  quiet=""
  # shellcheck disable=SC2016
  redir='>"$0.out" 2>&1'
fi

# Cmd's deadline SIGTERMs this script; the podman inside must get it too,
# or it outlives the caller's permit.
trap 'docker exec "$c" sh -c "kill \$(cat \"\$0.pid\") 2>/dev/null; rm -f \"\$0.out\" \"\$0.pid\"" "$id" >/dev/null 2>&1; exit 143' TERM INT HUP

# The status is renamed into place so a poll never reads a half-written one.
# shellcheck disable=SC2086
if ! docker exec -d $envs "$c" sh -c "podman \"\$@\" $redir & echo \$! > \"\$0.pid\"; wait \$!; echo \$? > \"\$0.rc.tmp\"; mv \"\$0.rc.tmp\" \"\$0.rc\"" "$id" $store "$@"; then
  echo "Error: wrapper: docker exec failed" >&2
  exit 125
fi

# Cmd's own deadline normally ends a call first; this only stops a wedged
# podman from holding the suite forever.
case "$sub" in pull) secs=600 ;; *) secs=180 ;; esac
end=$(($(date +%s) + secs))
until docker exec "$c" test -f "$id.rc"; do
  if [ "$(date +%s)" -ge "$end" ]; then
    echo "Error: wrapper: podman $sub still running after ${secs}s" >&2
    exit 125
  fi
  sleep 0.05
done

if [ -n "$quiet" ]; then
  docker exec "$c" cat "$id.out" >&2
else
  docker exec "$c" cat "$id.out"
fi
rc=$(docker exec "$c" sh -c 'cat "$0.rc"; rm -f "$0.out" "$0.rc" "$0.pid"' "$id")
exit "$rc"
