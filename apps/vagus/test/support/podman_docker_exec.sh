#!/bin/sh
# A `podman` for the opt-in :podman suite on a dev machine: runs the real
# podman inside a container on the host's Docker. Forwards the profile's Go
# env and the value of every value-less `--env NAME`, as the BEAM-side
# runner sets them. CONTAINERS_CONF_OVERRIDE is not forwarded: its path
# exists only on the BEAM side.
c=${VAGUS_PODMAN_CONTAINER:-vagus-podman-fixtures}

envs=""
for name in GOMAXPROCS GOMEMLIMIT GOGC; do
  eval "isset=\${$name+x}"
  [ -n "$isset" ] && envs="$envs -e $name"
done

prev=""
sub=""
for a in "$@"; do
  if [ "$prev" = "--env" ]; then
    case "$a" in *=*) ;; *) envs="$envs -e $a" ;; esac
  fi
  case "$a" in --log-level=*|--transient-store) ;; *) [ -z "$sub" ] && sub=$a ;; esac
  prev=$a
done

if [ "$sub" != "pull" ]; then
  # shellcheck disable=SC2086
  exec docker exec $envs "$c" podman "$@"
fi

# `docker exec` of a `podman pull` returns early and loses its output and
# status, so the pull runs to files inside and is polled for.
id="vw.$$.$(date +%s%N)"
# shellcheck disable=SC2086
docker exec $envs "$c" sh -c "podman \"\$@\" > /tmp/$id.out 2>&1; echo \$? > /tmp/$id.rc" sh "$@" >/dev/null 2>&1
tries=0
until docker exec "$c" test -f "/tmp/$id.rc"; do
  tries=$((tries + 1))
  # 10 minutes, past any pull the suite makes.
  if [ "$tries" -gt 3000 ]; then echo "Error: wrapper: pull never finished" >&2; exit 125; fi
  sleep 0.2
done
docker exec "$c" cat "/tmp/$id.out"
rc=$(docker exec "$c" cat "/tmp/$id.rc")
docker exec "$c" rm -f "/tmp/$id.out" "/tmp/$id.rc"
exit "$rc"
