#!/bin/sh
set -eu
# Generic Docker cron scheduler.
# Reads SCHEDULE_N / COMMAND_N / TIMEOUT_N env var triples and generates a crontab.
# All command output goes to container stdout/stderr for log collection.
#
# BusyBox crond has no anacron-style catch-up: schedules that fire while
# the container is down are silently skipped. monitor-backups.sh is the
# detection surface for missed backup work; drift from a skipped sync is
# only surfaced at the next successful run.
#
# Environment:
#   SCHEDULE_N             — 5-field cron expression (minute hour dom month dow)
#                            using only digits and the metacharacters * , / -
#                            (no day-of-week names like MON, no @macros).
#   COMMAND_N              — shell command to run on that schedule.
#   TIMEOUT_N              — (optional) per-job wall-clock timeout in seconds.
#                            Range [30, 86400] (30s–24h). Defaults to 7200 (2h)
#                            if unset. Used by run-job.sh with `timeout -k 30`.
#                            Tune per-job from observed p95 duration + 2–3×
#                            growth headroom (see operations.md Lessons Learned).
#   SCHEDULE_1..99 / COMMAND_1..99 / TIMEOUT_1..99 triples are read;
#   empty SCHEDULE+COMMAND pairs are skipped.
#   TZ                     — timezone (inherited from base template)

CRONTAB="/var/spool/cron/crontabs/root"
mkdir -p "$(dirname "$CRONTAB")"
: >"$CRONTAB"
printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
	>>"$CRONTAB"

# ---------------------------------------------------------------------------
# Input validation — source shared library for validate_no_control_chars.
# validate_timeout is docker-cron-specific (range check) and stays inlined.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. /usr/local/lib/validate.sh

# ---------------------------------------------------------------------------
# Structured log helper — unified format: level=<lvl> msg="<msg>" [key=val...]
# Usage: log_emit <level> <msg> [key=val ...]
# ---------------------------------------------------------------------------
log_emit() {
	_le_level="$1"
	_le_msg="$2"
	shift 2
	printf 'level=%s msg="%s"' "$_le_level" "$_le_msg"
	for _le_kv in "$@"; do
		printf ' %s' "$_le_kv"
	done
	printf '\n'
} >&2

log_emit info "docker-cron starting" "hostname=$(hostname)" "tz=${TZ:-UTC}"

# Timeout range bounds (seconds): minimum 30s, maximum 24h.
readonly TIMEOUT_MIN=30
readonly TIMEOUT_MAX=86400

# Validate timeout is a positive integer in [TIMEOUT_MIN, TIMEOUT_MAX] seconds.
validate_timeout() {
	case "$2" in
	'' | *[!0-9]*)
		log_emit error "TIMEOUT must be a positive integer" "var=$1" "value=$2"
		exit 1
		;;
	esac
	if [ "$2" -lt "$TIMEOUT_MIN" ] || [ "$2" -gt "$TIMEOUT_MAX" ]; then
		log_emit error "TIMEOUT out of range [${TIMEOUT_MIN}, ${TIMEOUT_MAX}]" "var=$1" "value=$2"
		exit 1
	fi
}

# Default per-job timeout (2h) when TIMEOUT_N is not set.
DEFAULT_TIMEOUT="${TIMEOUT_DEFAULT:-7200}"
validate_timeout "TIMEOUT_DEFAULT" "$DEFAULT_TIMEOUT"

# ---------------------------------------------------------------------------
# Build crontab from SCHEDULE_N / COMMAND_N / TIMEOUT_N triples.
# run-job is COPYed into /usr/local/bin by the Dockerfile — no runtime write.
#
# Data-driven approach: resolve env vars via a helper that uses printenv,
# eliminating eval entirely. Makes data flow explicit and allows shellcheck
# to fully analyze the script.
# ---------------------------------------------------------------------------

# Resolve a numbered env var (e.g. get_env_var SCHEDULE 3 → value of SCHEDULE_3).
# Returns empty string if the variable is unset.
get_env_var() {
	printenv "${1}_${2}" 2>/dev/null || true
}

job_count=0
i=1
while [ "$i" -le 99 ]; do
	schedule=$(get_env_var SCHEDULE "$i")
	cmd=$(get_env_var COMMAND "$i")
	timeout_val=$(get_env_var TIMEOUT "$i")

	if [ -z "$schedule" ] && [ -z "$cmd" ]; then
		i=$((i + 1))
		continue
	fi

	if [ -z "$schedule" ] || [ -z "$cmd" ]; then
		if [ -n "$schedule" ]; then
			missing="COMMAND"
		else
			missing="SCHEDULE"
		fi
		log_emit warn "incomplete job — ${missing}_${i} not set" "job=$i"
		i=$((i + 1))
		continue
	fi

	validate_no_control_chars "SCHEDULE_${i}" "$schedule"
	validate_no_control_chars "COMMAND_${i}" "$cmd"

	if [ -n "$timeout_val" ]; then
		validate_timeout "TIMEOUT_${i}" "$timeout_val"
		effective_timeout="$timeout_val"
	else
		effective_timeout="$DEFAULT_TIMEOUT"
	fi

	# Validate cron expression has exactly 5 fields (minute hour dom month dow)
	field_count=$(printf '%s' "$schedule" | awk '{print NF}')
	if [ "$field_count" -ne 5 ]; then
		log_emit error "invalid cron expression (need 5 fields)" "var=SCHEDULE_${i}" "value=$schedule" "fields=$field_count"
		exit 1
	fi

	# Validate cron fields contain only safe characters (defense-in-depth)
	case "$schedule" in
	*[!0-9\ */,-]*)
		log_emit error "invalid cron characters (use digits and * , / -)" "var=SCHEDULE_${i}" "value=$schedule"
		exit 1
		;;
	esac

	# Escape % → \% (crontab treats unescaped % as newline + stdin)
	escaped_cmd=$(printf '%s' "$cmd" | sed 's/%/\\%/g')
	# Format: <cron-expr> run-job <N> <timeout> <cmd> >> PID-1-stdout 2>> PID-1-stderr
	printf '%s run-job %d %d %s >> /proc/1/fd/1 2>> /proc/1/fd/2\n' \
		"$schedule" "$i" "$effective_timeout" "$escaped_cmd" >>"$CRONTAB"
	log_emit info "registered job" "job=$i" "schedule=$schedule" "timeout=${effective_timeout}s" "command=$(printf '%s' "$cmd" | sed 's/"/\\"/g')"
	job_count=$((job_count + 1))
	i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Start crond. Fail fast when zero jobs are configured: crash-looping is
# intentional so Komodo surfaces misconfiguration as a deploy failure rather
# than a healthy-but-idle container.
# ---------------------------------------------------------------------------
if [ "$job_count" -eq 0 ]; then
	log_emit error "no jobs configured — define SCHEDULE_N and COMMAND_N env vars"
	exit 1
fi

log_emit info "starting crond" "jobs=$job_count" "tz=${TZ:-UTC}"

# -f = foreground (PID 1), -l 6 = log level info
exec crond -f -l 6
