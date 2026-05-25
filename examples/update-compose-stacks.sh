#!/bin/sh
# update-compose-stacks.sh — Pull latest images and recreate containers
# for one or more Docker Compose stacks.
#
# Usage:
#   update-compose-stacks.sh <stack-dir> [<stack-dir> ...]
#
# Each <stack-dir> must contain a compose.yaml (or docker-compose.yaml).
# Both the script and the stack directories must be bind-mounted into the
# docker-cron container; the Docker socket must be mounted too.
#
# Example via docker-cron — daily at 04:00:
#   SCHEDULE_1: "0 4 * * *"
#   COMMAND_1:  "/scripts/update-compose-stacks.sh /stacks/app-a /stacks/app-b"
#   TIMEOUT_1:  "1800"   # 30 minutes
#
# Idempotent — running this when nothing has changed is effectively a
# no-op. `docker compose pull` only downloads new image digests, and
# `docker compose up -d` only recreates containers whose definition or
# image actually changed.

set -eu

log() {
  printf 'source=update-compose level=%s msg="%s" stack=%s\n' "$1" "$2" "$3"
}

if [ $# -lt 1 ]; then
  echo "usage: $0 <stack-dir> [<stack-dir> ...]" >&2
  exit 2
fi

failed=0

for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    log error "stack directory missing" "$dir"
    failed=$((failed + 1))
    continue
  fi

  found=0
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$dir/$f" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    log warn "no compose file found, skipping" "$dir"
    continue
  fi

  log info "pulling images" "$dir"
  if ! docker compose --project-directory "$dir" pull --quiet; then
    log error "docker compose pull failed" "$dir"
    failed=$((failed + 1))
    continue
  fi

  log info "recreating containers" "$dir"
  if ! docker compose --project-directory "$dir" up --detach --remove-orphans; then
    log error "docker compose up failed" "$dir"
    failed=$((failed + 1))
    continue
  fi

  log info "stack updated" "$dir"
done

# Optional: prune dangling images left behind by image updates.
# Uncomment if you want this cleanup. Note that `image prune` affects
# the entire host's image cache, not just the stacks updated above.
#
# docker image prune --force

if [ "$failed" -gt 0 ]; then
  printf 'source=update-compose level=error msg="%d stack(s) failed"\n' "$failed" >&2
  exit 1
fi
