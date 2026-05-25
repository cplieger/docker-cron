# docker-cron

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-cron)](https://github.com/cplieger/docker-cron/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-cron/size)](https://github.com/cplieger/docker-cron/pkgs/container/docker-cron)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: docker 29-cli](https://img.shields.io/badge/base-docker_29--cli-2496ED?logo=docker)

Generic Docker cron scheduler with per-job timeouts, locks, and structured logs

## Overview

A small cron scheduler designed for running Docker-related tasks (or any
shell command) on a schedule. Configure jobs via numbered environment
variables — `SCHEDULE_1`/`COMMAND_1`/`TIMEOUT_1`,
`SCHEDULE_2`/`COMMAND_2`/`TIMEOUT_2`, etc. — and the container generates a
crontab at startup, then runs busybox `crond` in the foreground.

Each job is wrapped in a thin script that adds:

- A per-job timeout with `SIGTERM` at the deadline, escalated to `SIGKILL`
  30 seconds later if the process ignores it
- A persistent `flock` so two firings of the same job can't run concurrently,
  and so a container restart mid-job is detectable on the next run
- Structured start/finish/exit logs for collection by Loki, Promtail, or any
  structured log scraper
- A "near timeout" warning when a job uses ≥70% of its configured timeout —
  useful for tuning before a job actually starts failing

**Example use case:** You want a database dump triggered nightly, an off-site
sync at 03:00, and a weekly cleanup task. Drop this container next to them
with the Docker socket mounted, set `SCHEDULE_1`/`COMMAND_1`,
`SCHEDULE_2`/`COMMAND_2`, etc., and the schedules just run. Logs go to stdout
in a structured format that any log aggregator can parse.

**Key features:**

- Configure up to 99 jobs via `SCHEDULE_N`/`COMMAND_N`/`TIMEOUT_N` env triples;
  gaps in the numbering are fine, partial pairs (only one of `SCHEDULE_N` or
  `COMMAND_N` set) log a warning and are skipped
- Per-job `flock` in a shared volume — survives container restarts so the
  wrapper can detect "previous container restarted mid-job" vs "another
  invocation is currently running"
- Per-job timeout, default 2 hours, configurable per job (range 30s–24h)
- 70% utilization warning before the timeout actually fires
- Structured logs (`source=run-job level=info ...`) on every start, finish,
  timeout, and failure
- Strict cron expression validation (5 fields, digits and `* , / -` only —
  no `@reboot`, no `MON`/`TUE`); `%` characters are auto-escaped so you
  don't have to think about crontab's newline-substitution rule
- Lock files contain plain-text metadata (`started`, `pid`, `timeout`,
  `command`) that you can inspect on a running job with
  `docker exec docker-cron cat /run/locks/job-<N>.lock`
- Crash-loops at startup on any invalid configuration, so a broken cron
  expression or out-of-range timeout surfaces as a deploy failure rather
  than a silent, healthy-but-idle container

This is a minimal Alpine-based container built on `docker:29-cli` — the base
image already includes the Docker CLI, so the most common use case (running
`docker exec` / `docker run` / `docker compose` from cron) works out of the
box. It runs as root because Docker socket access requires it.

### How It Differs From plain busybox crond / mcuadros/ofelia

The upstream [busybox crond](https://busybox.net/) is just a cron
implementation — you bring your own crontab, your own logging, and your own
timeout handling. This image adds:

- Env-driven configuration: no crontab file to mount or template
- Per-job `flock` with cross-restart awareness (orphan detection)
- Per-job `timeout -k` wrapper with structured exit-code reporting
- Strict cron expression validation at startup (catches typos before the
  first scheduled run)
- Structured `level=info|warn|error msg="..."` logs for every job event

Compared to [mcuadros/ofelia](https://github.com/mcuadros/ofelia) (a popular
Go-based docker-aware cron):

- Schedules run shell commands, not Docker exec actions specifically — you
  get the full power of `sh -c` (pipes, redirects, multi-step commands)
- No JSON or label-based config — env vars only
- No Go runtime, no daemon framework — just busybox `crond` and two short
  shell scripts (entrypoint + per-job wrapper)
- Simpler model: the container holds the schedule, not the targets; there's
  no introspection of other containers' labels

### Limitations

- **No anacron-style catch-up.** BusyBox `crond` does not run jobs whose
  scheduled time fell inside a window where the container was stopped or
  the host was off. If a daily 02:00 job misses its slot, it simply runs
  next at the next 02:00. For backup-style schedules where missing a run
  matters, alert on the absence of a `job finished` log line within an
  expected window rather than relying on retroactive execution.
- **Downstream `docker exec` processes are not killed on timeout.** When a
  job's timeout fires, the wrapper sends `SIGTERM` (then `SIGKILL`) to the
  local `sh -c` process. Docker's exec API does not propagate signals into
  the target container, so the remote process keeps running until it
  finishes naturally — and the next firing of the same job can overlap
  with that orphan. Design jobs to be idempotent.

## Container Registries

This image is published to both GHCR and Docker Hub:

| Registry | Image |
|----------|-------|
| GHCR | `ghcr.io/cplieger/docker-cron` |
| Docker Hub | `docker.io/cplieger/docker-cron` |

```bash
# Pull from GHCR
docker pull ghcr.io/cplieger/docker-cron:latest

# Pull from Docker Hub
docker pull cplieger/docker-cron:latest
```

Both registries receive identical images and tags. Use whichever you prefer.

## Quick Start

```yaml
services:
  docker-cron:
    image: ghcr.io/cplieger/docker-cron:latest
    container_name: docker-cron
    restart: unless-stopped
    user: "0:0"  # required for docker socket access

    environment:
      TZ: "Europe/Paris"

      # Job 1 — nightly database dump at 02:00
      SCHEDULE_1: "0 2 * * *"
      COMMAND_1: "docker exec my-db pg_dump -U postgres mydb > /backups/mydb.sql"
      TIMEOUT_1: "3600"   # 1h

      # Job 2 — weekly cleanup at 04:00 every Sunday
      SCHEDULE_2: "0 4 * * 0"
      COMMAND_2: "docker exec my-app find /tmp -mtime +7 -delete"
      TIMEOUT_2: "300"    # 5 min

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # Mount /backups too if your jobs write dumps to the host
      - "/opt/appdata/backups:/backups"
      # Lock files persist across container restarts so the wrapper can
      # detect "previous container restarted mid-job" vs "another invocation
      # is currently running". Use a non-tmpfs host path.
      - "/opt/appdata/docker-cron/locks:/run/locks"
```

## Deployment

1. Define one or more job triples — `SCHEDULE_N`, `COMMAND_N`, and optionally
   `TIMEOUT_N` — for `N` between 1 and 99. Triples don't have to be
   contiguous; the entrypoint scans 1..99 and silently skips slots where
   both `SCHEDULE_N` and `COMMAND_N` are empty. If only one of the two is
   set, that slot is logged as `incomplete job` and skipped (it does not
   crash the container).
2. Use a 5-field cron expression for `SCHEDULE_N`:
   `<minute> <hour> <day-of-month> <month> <day-of-week>`. Only digits and
   `*`, `,`, `/`, `-` are accepted. `@reboot`, `@daily`, and weekday names
   like `MON` are explicitly **not** supported (they're rejected at startup
   and crash the container).
3. `COMMAND_N` is a shell command run via `sh -c`. Pipes, redirects,
   environment variable expansion (resolved at job-run time), and multi-step
   commands all work. `%` characters are auto-escaped by the entrypoint
   so you don't have to think about crontab's "newline + stdin" rule.
4. `TIMEOUT_N` is the per-job wall-clock timeout in seconds. Range: 30–86400
   (30s–24h). When unset, the wrapper uses `TIMEOUT_DEFAULT` (default
   7200s / 2h). Both `TIMEOUT_N` and `TIMEOUT_DEFAULT` are range-validated
   at startup; out-of-range values crash the container.
5. Mount `/var/run/docker.sock` if your jobs need to call `docker exec`,
   `docker run`, or `docker compose`. The container runs as root because
   Docker socket access requires it.
6. Mount a persistent host directory at `/run/locks` so the per-job lock
   files survive container restarts. This lets the wrapper detect
   "previous container restarted mid-job" — see Limitations for the
   downstream-process caveat that goes with this.
7. The container will crash-loop at startup if no valid jobs are configured,
   if any cron expression has the wrong field count or contains invalid
   characters, or if any timeout falls outside the allowed range. This is
   intentional — it surfaces misconfiguration as a deploy failure rather
   than as a silent, healthy-but-idle container.

## Examples

The repo's [`examples/`](examples/) directory has ready-to-use scripts
demonstrating common patterns. Each example is meant to be bind-mounted
into the docker-cron container — they are **not** baked into the image,
so you can edit them freely or write your own.

| Script | What it does |
|--------|--------------|
| [`examples/update-compose-stacks.sh`](examples/update-compose-stacks.sh) | Pulls latest images and recreates containers for one or more Docker Compose stacks |

### Setting up `update-compose-stacks.sh`

1. Copy the script from the repo's `examples/` directory to a location on
   your host (or clone the repo and reference the path directly).
2. Mount the script read-only into docker-cron at a stable path like
   `/scripts/update-compose-stacks.sh`.
3. For each Compose stack you want to keep up to date, mount its
   directory (the one containing `compose.yaml`) read-only into the
   container under `/stacks/<name>`.
4. Add a job triple that calls the script with one or more stack paths.

A complete compose example:

```yaml
services:
  docker-cron:
    image: ghcr.io/cplieger/docker-cron:latest
    container_name: docker-cron
    restart: unless-stopped
    user: "0:0"  # required for docker socket access

    environment:
      TZ: "Europe/Paris"

      # Update two compose stacks daily at 04:00
      SCHEDULE_1: "0 4 * * *"
      COMMAND_1: "/scripts/update-compose-stacks.sh /stacks/app-a /stacks/app-b"
      TIMEOUT_1: "1800"  # 30 minutes — raise if your images are large

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - "/opt/appdata/docker-cron/locks:/run/locks"

      # The example script — copy from the repo's examples/ directory
      - "/path/to/update-compose-stacks.sh:/scripts/update-compose-stacks.sh:ro"

      # Each stack you want to keep up to date (must contain a compose.yaml)
      - "/path/to/data/app-a:/stacks/app-a:ro"
      - "/path/to/data/app-b:/stacks/app-b:ro"
```

The script is idempotent — running it when nothing has changed is
effectively a no-op (`docker compose pull` only downloads new image
digests, and `docker compose up -d` only recreates containers whose
definition or image actually changed). Schedule it as frequently as
you want.

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone — affects when cron expressions fire | `UTC` | No |
| `SCHEDULE_N` | 5-field cron expression for job `N` (1..99). Only digits and `*`, `,`, `/`, `-` accepted; no `@reboot`, no weekday names. | - | At least one |
| `COMMAND_N` | Shell command for job `N`. Run via `sh -c`. | - | At least one |
| `TIMEOUT_N` | Per-job wall-clock timeout in seconds for job `N`. Range 30–86400. | `TIMEOUT_DEFAULT` | No |
| `TIMEOUT_DEFAULT` | Default timeout for jobs that don't specify `TIMEOUT_N`. Range 30–86400. | `7200` (2h) | No |

## Volumes

| Mount | Description |
|-------|-------------|
| `/var/run/docker.sock` | Docker socket. Required if your jobs call `docker exec`, `docker run`, or `docker compose`. |
| `/run/locks` | Per-job lock files (`job-N.lock`). Mount a persistent host path so locks survive container restarts and the wrapper can detect orphan jobs. |

## Docker Healthcheck

The container ships a built-in Docker healthcheck (interval 30s, timeout 5s,
3 retries, 15s start period) that runs `pidof crond` to verify the busybox
`crond` process is still alive.

**When it becomes unhealthy:**

- `crond` crashed or exited unexpectedly
- The container is starting up (during `start_period`)

**When it recovers:**

- `crond` is restarted by Docker. The `restart: unless-stopped` policy in
  the example compose brings the container back, which restarts `crond`.

| Type | Command | Meaning |
|------|---------|---------|
| Process | `pidof crond` | Exit 0 = `crond` is running |

The healthcheck only confirms the scheduler process is alive — it does not
verify that individual jobs are succeeding. Job results are visible in the
container logs as structured `source=run-job` lines; alert on `level=error`
lines (job failures and timeouts) via Loki/Grafana, or any log alerting tool.

## Logging

Every job event — start, finish, failure, timeout, near-timeout, and
restart-orphan — is emitted as a structured log line on the container's
stdout/stderr. Anything your command itself writes to stdout or stderr
also lands in `docker logs` alongside the wrapper's lines.

```
source=run-job level=info  msg="job started"  job=1 timeout=3600s
source=run-job level=info  msg="job finished" job=1 exit=0 duration=412s
source=run-job level=warn  msg="job near timeout ceiling — consider raising TIMEOUT_1" job=1 exit=0 duration=2580s timeout=3600s utilization=71%
source=run-job level=error msg="job timed out" job=2 exit=124 duration=300s timeout=300s reason=timeout
source=run-job level=error msg="job failed"   job=3 exit=1   duration=12s
source=run-job level=warn  msg="previous run orphaned by container restart — starting new run" job=1 prev_age=180s timeout=3600s
```

Timeouts surface as `reason=timeout` whether the underlying `timeout`
binary is GNU coreutils (exit 124) or BusyBox (exit 143), so log-based
alert rules can key on a single field across base images.

## Security

This is a thin scheduler — input handling is the main concern. The
container:

- Validates every `SCHEDULE_N` is exactly 5 whitespace-separated fields
  containing only digits and the cron metacharacters `* , / -`. Anything
  outside that set — including `;`, `&`, `|`, `$`, `` ` ``, alphabetics,
  and shell quoting — is rejected before the crontab is written.
- Rejects any control character (newlines, carriage returns, etc.) in
  `SCHEDULE_N` and `COMMAND_N` to prevent crontab injection
- Validates `TIMEOUT_N` and `TIMEOUT_DEFAULT` are positive integers in the
  30–86400 range
- Crash-loops at startup if any validation fails — bad config never reaches
  `crond`

`COMMAND_N` is intentionally passed verbatim to `sh -c`. The shell does
what shells do — pipes, redirects, command substitution. Treat env-var
supplied commands as trusted; don't accept them from untrusted sources.

This container runs as **root** because Docker socket access requires it.
The Docker socket is equivalent to root on the host — anyone able to write
to `COMMAND_N` (or to the compose file) can escalate to host root.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| docker | `29-cli` | [Docker Hub](https://hub.docker.com/_/docker) |

## Design Principles

- **Always up to date**: Base images and libraries are updated automatically via Renovate.
- **Minimal attack surface**: Just busybox `crond` plus two thin shell scripts (entrypoint + per-job wrapper). No Go binary, no Python, no daemon framework.
- **Digest-pinned**: Every `FROM` instruction pins a SHA256 digest. All GitHub Actions are digest-pinned.
- **Multi-platform**: Built for `linux/amd64` and `linux/arm64`.
- **Healthchecks**: The built-in `HEALTHCHECK` confirms `crond` is running.
- **Provenance**: Build provenance is attested via GitHub Actions, verifiable with `gh attestation verify`. SBOMs are generated with Syft and signed with Cosign.

## Credits

This is an original tool that builds upon [BusyBox `crond`](https://busybox.net/).
- [BusyBox](https://busybox.net/) — `crond` and `timeout -k`
- [Docker CLI](https://github.com/docker/cli) — Docker Engine client used
  by jobs that call `docker exec` / `docker run`

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
