#!/bin/sh
set -u
# Job wrapper — logs start/finish with exit code to container stdout/stderr.
# Usage: run-job <job-number> <timeout-seconds> <command-words...>
#
# Command words are joined via $* and executed via sh -c so pipes, redirects,
# and other shell constructs work correctly. COMMAND_N values therefore must
# not rely on preserved quoting around arguments with embedded whitespace
# (crontab parses once, then sh -c parses the joined string again).
#
# Structured log fields are prefixed with source=run-job so Loki / Grafana
# alert rules can distinguish wrapper-level events from downstream command
# output (e.g. Kopia also emits level=... lines natively).

# Exit codes from timeout(1): 124 = timed out (GNU coreutils),
# 143 = SIGTERM-killed (BusyBox). Kill-grace = seconds between SIGTERM and SIGKILL.
readonly EXIT_TIMEOUT=124
readonly EXIT_SIGTERM=143
readonly KILL_GRACE=30

# ---------------------------------------------------------------------------
# Structured log helper — unified format: source=run-job level=<lvl> msg="<msg>" [key=val...]
# Usage: log_emit <level> <msg> [key=val ...]
# ---------------------------------------------------------------------------
log_emit() {
	_le_level="$1"
	_le_msg="$2"
	shift 2
	printf 'source=run-job level=%s msg="%s"' "$_le_level" "$_le_msg"
	for _le_kv in "$@"; do
		printf ' %s' "$_le_kv"
	done
	printf '\n'
} >&2
#
# ---------------------------------------------------------------------------
# Lock & timeout model
# ---------------------------------------------------------------------------
# Lock files live under /run/locks (a host bind mount, not /tmp) so they
# survive container restarts. The kernel-level `flock` resets cleanly on
# container start regardless of the on-disk file, so a crashed previous
# container never leaves a kernel-held lock behind — only an on-disk file
# we can read for metadata.
#
# Three cases the wrapper distinguishes:
#   (A) flock -n succeeds, file mtime is recent (< timeout):
#       Previous container restarted mid-job. Orphaned docker exec may still
#       be running inside the downstream container. Log warn + proceed; downstream
#       commands are idempotent (kopia sync-to, pg_dump atomic-rename, monitor,
#       verify). Operator accepts this trade-off.
#   (B) flock -n fails:
#       Another invocation is actively running in THIS container. Skip with warn.
#   (C) flock -n succeeds, file mtime is old (>= timeout) or missing:
#       Normal path. Acquire lock, update mtime, run command.
#
# The `timeout -k $KILL_GRACE <N>` wrapper sends SIGTERM at the configured timeout and
# SIGKILL $KILL_GRACE seconds later if the process ignores it. Exit code EXIT_TIMEOUT means timed out.
#
# ---------------------------------------------------------------------------
# Orphaned docker exec caveat
# ---------------------------------------------------------------------------
# When timeout fires, the `sh -c "docker exec <container> <cmd>"` client dies,
# releasing our flock. But the downstream process inside <container> does NOT
# receive a signal — `docker exec` does not propagate termination to the
# remote process. The remote process continues until it exits on its own.
# A subsequent cron fire of the same job will find the flock free (correct)
# and may start a second downstream run concurrent with the orphaned one.
#
# This is acceptable because every configured job is idempotent by design:
#   - kopia sync-to: idempotent (source→target diff)
#   - pg_dump via db-dumper CGI: writes temp file then atomic rename
#   - monitor-backups.sh: read-only reporting
#   - verify-snapshots.sh: read-only verification
#   - restore-test.sh: writes to scratch dir that it creates per run
#
# `set -e` is deliberately OFF: the script captures `timeout ... sh -c "$*"`'s
# exit code into `rc` so it can log a distinct level=error for failures. With
# `set -e` the capture would be unreachable on non-zero exits.

if [ $# -lt 3 ]; then
	log_emit error "usage: run-job <N> <timeout-sec> <cmd...>"
	exit 2
fi
job="$1"
timeout_sec="$2"
shift 2

lockfile="/run/locks/job-${job}.lock"
mkdir -p /run/locks 2>/dev/null || true

# Capture mtime BEFORE opening the lock file. Opening in append mode creates
# the file with a current mtime, which would always trigger the orphan-detection
# path. On first run the file is missing → prev_mtime=0 (our fallback).
if [ -e "$lockfile" ]; then
	prev_mtime=$(stat -c %Y "$lockfile" 2>/dev/null || echo 0)
else
	prev_mtime=0
fi

# Open the lock file (fd 9). Creates it if missing.
exec 9>>"$lockfile"

if ! flock -n 9; then
	log_emit warn "job already running, skipping" "job=$job" "lockfile=$lockfile"
	exit 0
fi

# Lock acquired. If mtime was recent (case A), log the restart-during-job case.
now=$(date +%s)
if [ "$prev_mtime" -gt 0 ]; then
	age=$((now - prev_mtime))
	if [ "$age" -lt "$timeout_sec" ]; then
		log_emit warn "previous run orphaned by container restart — starting new run" "job=$job" "prev_age=${age}s" "timeout=${timeout_sec}s"
	fi
fi

# Update mtime (touching the file) and overwrite metadata for debuggability.
# Readers: `docker exec docker-cron cat /run/locks/job-<N>.lock`.
start=$(date +%s)
{
	printf 'started=%s\n' "$start"
	printf 'pid=%s\n' "$$"
	printf 'timeout=%s\n' "$timeout_sec"
	printf 'command=%s\n' "$*"
} >&9

log_emit info "job started" "job=$job" "timeout=${timeout_sec}s"

# `timeout -k $KILL_GRACE`: graceful SIGTERM at timeout_sec, SIGKILL after KILL_GRACE seconds.
# Exit code EXIT_TIMEOUT from GNU coreutils timeout = timed out (BusyBox uses EXIT_SIGTERM for
# SIGTERM-killed processes; we match both to be portable across base images).
timeout -k "$KILL_GRACE" "$timeout_sec" sh -c "$*"
rc=$?
elapsed=$(($(date +%s) - start))

if [ "$rc" -eq 0 ]; then
	# Surface slow-but-successful runs approaching the timeout ceiling so the
	# operator can tighten or loosen TIMEOUT_N before it starts causing outages.
	# Threshold: 70% of configured timeout.
	threshold=$((timeout_sec * 70 / 100))
	if [ "$elapsed" -ge "$threshold" ]; then
		log_emit warn "job near timeout ceiling — consider raising TIMEOUT_${job}" "job=$job" "exit=0" "duration=${elapsed}s" "timeout=${timeout_sec}s" "utilization=$((elapsed * 100 / timeout_sec))%"
	else
		log_emit info "job finished" "job=$job" "exit=0" "duration=${elapsed}s"
	fi
elif [ "$rc" -eq "$EXIT_TIMEOUT" ] || [ "$rc" -eq "$EXIT_SIGTERM" ]; then
	log_emit error "job timed out" "job=$job" "exit=$rc" "duration=${elapsed}s" "timeout=${timeout_sec}s" "reason=timeout"
else
	log_emit error "job failed" "job=$job" "exit=$rc" "duration=${elapsed}s"
fi
exit "$rc"
