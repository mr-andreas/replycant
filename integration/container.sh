#!/bin/bash
set -euo pipefail

image="replycant-integration:test"
id_file="/tmp/replycant-integration-container-id"

# require_local_daemon fails fast when published ports would land on another host.
# The iOS simulator reaches the stack over the Mac's loopback, so a remote
# DOCKER_HOST leaves the container healthy but unreachable from the tests.
require_local_daemon() {
  if [[ -n "${DOCKER_HOST:-}" && "$DOCKER_HOST" != unix://* ]]; then
    echo "DOCKER_HOST=$DOCKER_HOST publishes ports off this machine; unset it so the simulator can reach the stack" >&2
    exit 1
  fi
}

# remove_stale_containers keeps test startup deterministic after interrupted runs.
remove_stale_containers() {
  local ids=""
  ids="$(docker ps -q --filter label=replycant-integration=true)"
  if [[ -n "$ids" ]]; then
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
}

# wait_for_ready blocks until gitd bootstraps and the control endpoint responds.
wait_for_ready() {
  local container_id="$1"
  local deadline=120

  for _ in $(seq 1 "$deadline"); do
    if docker exec "$container_id" test -f /tmp/ready >/dev/null 2>&1; then
      if curl -fsS "http://localhost:18447/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done

  echo "integration container failed readiness checks" >&2
  docker logs "$container_id" >&2 || true
  return 1
}

# start_container builds and starts the shared integration stack for iOS tests.
start_container() {
  require_local_daemon
  remove_stale_containers
  docker build -f integration/Dockerfile -t "$image" .
  local container_id
  container_id="$(
    docker run --rm -d \
      --label replycant-integration=true \
      -p 18080:8080 \
      -p 18443:18443 \
      -p 18444:18444 \
      -p 18447:18447 \
      "$image"
  )"
  echo "$container_id" > "$id_file"
  wait_for_ready "$container_id"
  echo "$container_id"
}

# stop_container tears down the integration stack started by this script.
stop_container() {
  local container_id=""
  if [[ -f "$id_file" ]]; then
    container_id="$(tr -d '\n' < "$id_file")"
  fi
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  rm -f "$id_file"
  remove_stale_containers
}

action="${1:-}"
case "$action" in
  start)
    start_container
    ;;
  stop)
    stop_container
    ;;
  *)
    echo "usage: integration/container.sh {start|stop}" >&2
    exit 1
    ;;
esac
