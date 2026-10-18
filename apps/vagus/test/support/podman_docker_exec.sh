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
grace=0
for a in "$@"; do
  if [ "$prev" = "--env" ]; then
    case "$a" in *=*) ;; *) envs="$envs -e $a" ;; esac
  fi
  case "$a" in --log-level=*|--transient-store) ;; *) [ -z "$sub" ] && sub=$a ;; esac
  if [ "$sub" = logs ]; then case "$a" in -f|--follow) follow=1 ;; esac; fi
  case "$prev" in --time|-t) case "$a" in ''|*[!0-9]*) ;; *) grace=$a ;; esac ;; esac
  prev=$a
done

store=""
if [ -n "$VAGUS_PODMAN_RUN" ]; then
  # It names directories the suite later deletes, so nothing may climb out.
  case "$VAGUS_PODMAN_RUN" in
    *[!A-Za-z0-9_.-]* | .* | -*)
      echo "Error: wrapper: bad VAGUS_PODMAN_RUN" >&2
      exit 125
      ;;
  esac
  store="--root /var/lib/vagus-test/$VAGUS_PODMAN_RUN --runroot /run/vagus-test/$VAGUS_PODMAN_RUN"
fi

# These stream until stopped, so there is no exit to wait for; the suite
# runs none of them (log follow and events read podman's files instead).
if [ "$sub" = events ] || [ "$sub" = attach ] || [ -n "$follow" ]; then
  # shellcheck disable=SC2086
  exec docker exec $envs "$c" podman $store "$@"
fi

# Here `docker exec` returns after about 0.5 s whatever the process is
# doing, with status 0 and no output, so anything longer runs detached, to
# files inside the container that are polled.
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

# The child publishes its pid and checks `.cancel` before it execs, so the
# pid it publishes is podman's: either it sees `.cancel` and never becomes
# podman, or cancel() sees the pid and kills it. The pid and the status
# are renamed into place so nothing ever reads half of one.
# shellcheck disable=SC2016
inner='sh -c "echo \$\$ > \"\$0.pid.tmp\" && mv \"\$0.pid.tmp\" \"\$0.pid\"
[ -e \"\$0.cancel\" ] && exit 130
exec podman \"\$@\"" "$0" "$@" '"$redir"' &
wait $!
echo $? > "$0.rc.tmp"
mv "$0.rc.tmp" "$0.rc"
[ -e "$0.cancel" ] && rm -f "$0.out" "$0.pid" "$0.rc" "$0.cancel"'

# Returns only once podman is gone: Cmd waits for muontrap, whose child is
# this script, so returning early would free the Host permit under a live
# podman. `.cancel` is set before the pid is read, the reverse of the
# child's order, so no pid read empty can ever become podman; such a late
# launch clears the markers itself. `podman run` passes a TERM to the
# container, whose PID 1 may ignore it, hence the KILL. muontrap SIGKILLs
# this script 3 s after its TERM, so the reap ends within 1.8 s (TERM
# grace 1.2 s) and polls cost about 0.05 s.
# shellcheck disable=SC2016
reap='f=$0
ms() { echo $(($(date +%s%N) / 1000000)); }
touch "$f.cancel"
p=$(cat "$f.pid" 2>/dev/null)
if [ -n "$p" ]; then
  if [ ! -e "$f.rc" ]; then
    kill "$p" 2>/dev/null
    end=$(($(ms) + 1200))
    while kill -0 "$p" 2>/dev/null && [ "$(ms)" -lt "$end" ]; do sleep 0.02; done
    kill -9 "$p" 2>/dev/null
    end=$(($(ms) + 300))
    while kill -0 "$p" 2>/dev/null && [ "$(ms)" -lt "$end" ]; do sleep 0.02; done
  fi
  end=$(($(ms) + 300))
  while [ ! -e "$f.rc" ] && [ "$(ms)" -lt "$end" ]; do sleep 0.02; done
  [ -e "$f.rc" ] && rm -f "$f.out" "$f.pid" "$f.rc" "$f.cancel"
fi
touch "$f.reaped"
sleep 3
rm -f "$f.reaped"'

# Not `%3N`: some dates (uutils) ignore its width and print nanoseconds.
now_ms() { echo $(($(date +%s%N) / 1000000)); }

# The reap runs detached and is polled for, like podman itself; its marker
# also removes itself, should this script be killed before it can.
cancel() {
  docker exec -d "$c" sh -c "$reap" "$id" >/dev/null 2>&1 || return
  end=$(($(now_ms) + 2600))
  until docker exec "$c" test -e "$id.reaped"; do
    [ "$(now_ms)" -ge "$end" ] && return
    sleep 0.05
  done
  docker exec "$c" rm -f "$id.reaped"
}

# Cmd's deadline SIGTERMs this script; the podman inside must get it too.
# The trap runs once the foreground docker exec or sleep returns, so at
# most a poll late.
trap 'cancel; exit 143' TERM INT HUP

# shellcheck disable=SC2086
if ! docker exec -d $envs "$c" sh -c "$inner" "$id" $store "$@"; then
  echo "Error: wrapper: docker exec failed" >&2
  exit 125
fi

# Past every deadline Cmd gives a call (a pull's hour; a stop's or restart's
# grace plus its margins), so Cmd always ends a call first and this only
# bounds a podman wedged beyond it.
case "$sub" in pull) secs=3660 ;; *) secs=$((300 + grace)) ;; esac
end=$(($(date +%s) + secs))
until docker exec "$c" test -f "$id.rc"; do
  if [ "$(date +%s)" -ge "$end" ]; then
    echo "Error: wrapper: podman $sub still running after ${secs}s" >&2
    cancel
    exit 125
  fi
  sleep 0.05
done

# podman has exited, so a signal from here on has nothing to cancel, and a
# reap would leave `.cancel` behind for a launch that already finished.
trap 'docker exec "$c" rm -f "$id.out" "$id.rc" "$id.pid" >/dev/null 2>&1; exit 143' TERM INT HUP

if [ -n "$quiet" ]; then
  docker exec "$c" cat "$id.out" >&2
else
  docker exec "$c" cat "$id.out"
fi
# shellcheck disable=SC2016
rc=$(docker exec "$c" sh -c 'cat "$0.rc"; rm -f "$0.out" "$0.rc" "$0.pid"' "$id")
# Empty when the container went away under the call.
exit "${rc:-125}"
