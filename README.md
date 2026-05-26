
![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-cron)](https://github.com/cplieger/docker-cron/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-cron/size)](https://github.com/cplieger/docker-cron/pkgs/container/docker-cron)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: docker 29-cli](https://img.shields.io/badge/base-docker_29--cli-2496ED?logo=docker)

Run scheduled tasks on your Docker host — backups, cleanup scripts,
image updates — with timeouts, locks, and structured logs.

## What it does

You give it a list of "run this command at this time" pairs as
environment variables, and it runs them on schedule. Typical use cases:

- Nightly database dump at 02:00
- Weekly cleanup of temporary files every Sunday at 04:00
- Hourly check for new container image versions

Under the hood it uses [BusyBox `cron`](https://busybox.net/) — Unix's
classic scheduler — but `cron` itself is bare-bones (no timeouts, no
logging, no concurrency control). This image wraps it with the extras
most people end up reinventing:

- **Per-job timeouts** — set a wall-clock cap; the job is killed cleanly
  if it overruns.
- **Locks** — two runs of the same job can't overlap, even after a
  container restart.
- **Structured logs** — every start, finish, failure, and timeout emits
  a parseable log line ready to ship to Loki, Grafana Agent, etc.
- **Strict validation** — typos in schedules or out-of-range timeouts
  crash the container at startup, so you catch them at deploy time and
  not when a backup silently fails to run.
- **Heads-up at 70%** — when a job uses ≥70% of its time budget, a
  warning log line lets you tune the budget before it starts failing.

### Why this design

Other Docker-aware cron tools introspect container labels, take JSON
config, or wrap a custom daemon framework. This image takes the
opposite approach:

- **Env-var configuration**, not crontab files or container labels.
  The container itself holds every schedule and command — nothing to
  template, no introspection of other containers' state.
- **Generic shell commands**, not container-action-specific verbs.
  Anything you can run in `sh -c` works (pipes, redirects, multi-step),
  so a job can call `docker exec`, `curl`, a Python script, or all
  three in sequence.
- **Two shell scripts on top of `crond`** — no Go runtime, no daemon
  framework. The whole thing is small enough to read end-to-end.

This is a minimal Alpine image based on `docker:29-cli`, so jobs can
call `docker exec`, `docker run`, or `docker compose` directly. It runs
as root because mounting the Docker socket requires it.

## Quick start

The image is published to both GHCR (`ghcr.io/cplieger/docker-cron`)
and Docker Hub (`cplieger/docker-cron`) — identical contents, use
whichever you prefer.

```yaml
services:
  docker-cron:
    image: ghcr.io/cplieger/docker-cron:latest
    container_name: docker-cron
    restart: unless-stopped
    user: "0:0"  # required for Docker socket access

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
      - "/opt/appdata/backups:/backups"
      # Persistent host path for lock files so they survive restarts
      - "/opt/appdata/docker-cron/locks:/run/locks"
```

Configure jobs as `SCHEDULE_N` / `COMMAND_N` / `TIMEOUT_N` triples for
`N` between 1 and 99. Numbering doesn't have to be contiguous — gaps
are fine.

## Configuration reference

### Environment variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone — controls when cron expressions fire | `UTC` | No |
| `SCHEDULE_N` | 5-field cron expression for job `N`. Only digits and `*`, `,`, `/`, `-` accepted; no `@reboot`, no weekday names like `MON`. | — | At least one job |
| `COMMAND_N` | Shell command for job `N`, run via `sh -c` (pipes, redirects, multi-step commands all work). `%` characters are auto-escaped. | — | At least one job |
| `TIMEOUT_N` | Wall-clock timeout in seconds for job `N`. Range 30–86400. | `TIMEOUT_DEFAULT` | No |
| `TIMEOUT_DEFAULT` | Default timeout for jobs that don't set their own. Range 30–86400. | `7200` (2h) | No |

### Volumes

| Mount | Description |
|-------|-------------|
| `/var/run/docker.sock` | Docker socket. Required if jobs use `docker exec` / `run` / `compose`. |
| `/run/locks` | Per-job lock files. Mount a persistent host path so locks survive container restarts and the wrapper can detect orphaned runs. |

## Examples

The repo's [`examples/`](examples/) directory has ready-to-use scripts
that bind-mount into the container — they aren't baked into the image,
so you can edit them or write your own.

| Script | What it does |
|--------|--------------|
| [`examples/update-compose-stacks.sh`](examples/update-compose-stacks.sh) | Pulls latest images and recreates containers for one or more Docker Compose stacks |

### Setting up `update-compose-stacks.sh`

1. Copy the script from `examples/` to a path on your host.
2. Mount it read-only at a stable path inside the container, e.g.
   `/scripts/update-compose-stacks.sh`.
3. For each Compose stack, mount its directory into the container at
   the **same path it has on the host**, read-write. Same path because
   Compose resolves relative bind mounts (`./data`, `./config`) against
   the project directory at runtime — if the path inside the container
   differs from the host path, the daemon receives source paths that
   don't exist on the host. Read-write because Compose may write
   project metadata to the directory during `up -d`.
4. Add a job that calls the script with one or more stack paths.

Complete compose example:

```yaml
services:
  docker-cron:
    image: ghcr.io/cplieger/docker-cron:latest
    container_name: docker-cron
    restart: unless-stopped
    user: "0:0"

    environment:
      TZ: "Europe/Paris"

      SCHEDULE_1: "0 4 * * *"
      COMMAND_1: "/scripts/update-compose-stacks.sh /opt/stacks/app-a /opt/stacks/app-b"
      TIMEOUT_1: "1800"  # 30 min — raise if your images are large

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - "/opt/appdata/docker-cron/locks:/run/locks"
      - "/path/to/update-compose-stacks.sh:/scripts/update-compose-stacks.sh:ro"
      # Stack mounts: same path inside as on the host (see step 3 above)
      - "/opt/stacks/app-a:/opt/stacks/app-a"
      - "/opt/stacks/app-b:/opt/stacks/app-b"
```

The script is idempotent — `docker compose pull` only downloads new
image digests, and `docker compose up -d` only recreates containers
whose definition or image actually changed. Schedule it as often as
you want.

## Logging

Every job event emits a single structured log line on stdout/stderr.
Anything the command itself writes also lands in `docker logs`
alongside the wrapper's lines.

```
source=run-job level=info  msg="job started"  job=1 timeout=3600s
source=run-job level=info  msg="job finished" job=1 exit=0 duration=412s
source=run-job level=warn  msg="job near timeout ceiling — consider raising TIMEOUT_1" job=1 exit=0 duration=2580s timeout=3600s utilization=71%
source=run-job level=error msg="job timed out" job=2 exit=124 duration=300s timeout=300s reason=timeout
source=run-job level=error msg="job failed"   job=3 exit=1   duration=12s
source=run-job level=warn  msg="previous run orphaned by container restart — starting new run" job=1 prev_age=180s timeout=3600s
```

Timeouts always surface as `reason=timeout` whether the underlying
`timeout` binary is GNU coreutils (exit 124) or BusyBox (exit 143), so
log-based alerts can key on a single field across base images.

Lock files at `/run/locks/job-<N>.lock` carry plain-text metadata
(`started`, `pid`, `timeout`, `command`) that you can inspect on a
running job:

```bash
docker exec docker-cron cat /run/locks/job-1.lock
```

## Healthcheck

The container's built-in healthcheck runs `pidof crond` every 30s — exit
0 means the scheduler is alive. It does **not** verify that individual
jobs are succeeding; alert on `level=error` log lines via Loki / Grafana
or your tool of choice for that.

## Limitations

- **No catch-up runs.** BusyBox `crond` doesn't run jobs whose scheduled
  time fell while the container was stopped. A daily 02:00 job that
  misses its slot waits until tomorrow's 02:00. For backups where
  missing a run matters, alert on the absence of a `job finished` log
  line within the expected window rather than hoping for retroactive
  execution.
- **`docker exec` processes survive timeouts.** When a job times out,
  the wrapper kills its local `sh -c` process. Docker's exec API does
  not propagate signals into the target container, so the remote
  process keeps running until it finishes naturally — and the next
  firing of the same job can overlap with that orphan. Design jobs to
  be idempotent.

## Security

- All `SCHEDULE_N` and `COMMAND_N` values are validated before they
  reach `crond`. Schedules must be 5 whitespace-separated fields of
  digits and `* , / -`; control characters (newline, CR) are rejected
  in both. Bad config crash-loops the container at startup.
- `COMMAND_N` is passed verbatim to `sh -c` — pipes, redirects, command
  substitution all work. Treat env-var-supplied commands as trusted;
  don't accept them from untrusted sources.
- The container runs as **root** because Docker socket access requires
  it. The Docker socket is equivalent to root on the host, so anyone
  able to write to `COMMAND_N` (or to your compose file) can escalate
  to host root. This is the standard tradeoff for any socket-mounting
  container.

## Dependencies

| Dependency | Version | Source |
|------------|---------|--------|
| docker | `29-cli` | [Docker Hub](https://hub.docker.com/_/docker) |

Updated automatically via [Renovate](https://github.com/renovatebot/renovate)
and pinned by digest. Builds carry signed SBOMs and provenance attestations
verifiable with `gh attestation verify`.

## Credits

- [BusyBox](https://busybox.net/) — `crond` and `timeout -k`
- [Docker CLI](https://github.com/docker/cli) — used by jobs that call
  `docker exec` / `run` / `compose`

## Disclaimer

These images are built with care and follow security best practices,
but they are intended for **homelab use**. No guarantees of fitness
for production environments. Use at your own risk.

This project was built with AI-assisted tooling using
[Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev).
The human maintainer defines architecture, supervises implementation,
and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
