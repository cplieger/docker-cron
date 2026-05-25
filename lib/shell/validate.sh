#!/bin/sh
# validate.sh — Shared POSIX validation functions for shell entrypoints.
# Sourced at runtime by entrypoint.sh; functions print structured log
# messages to stderr and return 1 on failure.
#
# Functions: validate_no_newlines, validate_no_control_chars, validate_numeric,
# validate_no_brackets, validate_no_quotes, validate_identifier,
# validate_no_path_traversal, validate_no_open_relay, validate_no_metacharacters,
# validate_tls_level, validate_spec_format.

# validate_no_newlines VAR_NAME VALUE
#   Reject values containing EMBEDDED newlines (prevents config injection).
#   A single trailing newline is allowed because it harmlessly survives env
#   substitution via $(...) (command substitution normally strips it, but
#   direct reads from files or explicit quoting preserve it). Embedded
#   newlines remain rejected because they are the actual injection vector
#   (multi-line values that inject new config directives).
validate_no_newlines() {
    # Strip one trailing newline before counting.
    # The `printf x` + `%x` trick preserves whether the original ended in \n:
    # - `$(printf '%s' "$2"; printf x)` gives "value\nx" or "valuex"
    # - We then strip the x, then strip at most one trailing \n.
    _val=$(printf '%s' "$2"; printf x)
    _val=${_val%x}
    _val=${_val%"
"}
    line_count=$(printf '%s' "$_val" | wc -l)
    if [ "$line_count" -gt 0 ]; then
        printf 'level=error msg="env var contains embedded newlines" var=%s\n' "$1" >&2
        return 1
    fi
}

# validate_no_control_chars VAR_NAME VALUE
#   Reject values containing any ASCII control character (prevents crontab/
#   config injection via \n, \r and log-line forging via other cntrl bytes).
#   POSIX [[:cntrl:]] covers 0x00-0x1F plus 0x7F, which includes horizontal
#   tab (\t) — callers that need to accept tabs should use validate_no_newlines
#   instead.
validate_no_control_chars() {
    case "$2" in
        *[[:cntrl:]]*)
            printf 'level=error msg="env var contains control characters" var=%s\n' "$1" >&2
            return 1
            ;;
    esac
}

# validate_numeric VAR_NAME VALUE
#   Reject empty or non-numeric values (positive integers only).
validate_numeric() {
    case "$2" in
        ''|*[!0-9]*)
            printf 'level=error msg="env var must be a positive integer" var=%s value="%s"\n' "$1" "$2" >&2
            return 1
            ;;
    esac
}

# validate_no_brackets VAR_NAME VALUE
#   Reject values containing [ or ] (prevents INI/NUT section injection).
validate_no_brackets() {
    case "$2" in
        *"["*|*"]"*)
            printf 'level=error msg="env var contains bracket characters" var=%s\n' "$1" >&2
            return 1
            ;;
    esac
}

# validate_no_quotes VAR_NAME VALUE
#   Reject values containing double-quote characters (prevents config
#   quoting breakout in INI-style config files like NUT).
validate_no_quotes() {
    case "$2" in
        *'"'*)
            printf 'level=error msg="env var contains double-quote" var=%s\n' "$1" >&2
            return 1
            ;;
    esac
}

# validate_identifier FIELD_NAME VALUE
#   Reject empty values or values with characters outside [a-zA-Z0-9_-].
#   Safe for use in shell command arguments (docker exec, pg_dump, etc.).
validate_identifier() {
    case "$2" in
        "")
            printf 'level=error msg="%s is empty"\n' "$1" >&2
            return 1
            ;;
        *[!a-zA-Z0-9_-]*)
            printf 'level=error msg="%s contains invalid characters" %s="%s"\n' \
                "$1" "$1" "$2" >&2
            return 1
            ;;
    esac
}

# validate_no_path_traversal VAR_NAME VALUE
#   Reject empty values or values containing ".." path traversal sequences.
validate_no_path_traversal() {
    case "$2" in
        "")
            printf 'level=error msg="%s is empty"\n' "$1" >&2
            return 1
            ;;
        *".."*)
            printf 'level=error msg="%s contains path traversal" var=%s\n' "$1" "$1" >&2
            return 1
            ;;
    esac
}

# validate_no_open_relay NETWORK_LIST
#   Reject 0.0.0.0/0 or ::/0 in a space-separated list of CIDR networks.
#   Also rejects entries missing a CIDR prefix, non-numeric prefixes, prefixes
#   shorter than /8 (>16M hosts, likely misconfiguration), and malformed IP
#   addresses on the network side (e.g. 999.999.999.999/8, 192.68.1.0/24
#   typo where a digit is missing). IPv6 addresses (containing `:`) are
#   accepted in structure and delegated to Postfix's own validation for
#   full shape checking; only the prefix portion is validated here.
validate_no_open_relay() {
    for _net in $1; do
        case "$_net" in
            0.0.0.0/0|::/0)
                printf 'level=error msg="network list contains open-relay CIDR" network=%s\n' "$_net" >&2
                return 1
                ;;
        esac
        _prefix="${_net##*/}"
        if [ "$_prefix" = "$_net" ]; then
            printf 'level=error msg="network entry missing CIDR prefix" network=%s\n' "$_net" >&2
            return 1
        fi
        case "$_prefix" in
            ''|*[!0-9]*)
                printf 'level=error msg="network entry has non-numeric prefix" network=%s\n' "$_net" >&2
                return 1
                ;;
        esac
        if [ "$_prefix" -lt 8 ]; then
            printf 'level=error msg="network CIDR too broad (min /8)" network=%s prefix=%s\n' "$_net" "$_prefix" >&2
            return 1
        fi

        # IP shape validation: catch typos like 192.68.1.0/24 (missing digit)
        # that would silently exclude the intended LAN from relaying. IPv4
        # requires four dotted octets each 0-255 and /0-/32 prefix. IPv6 is
        # detected by the presence of `:` and delegated to Postfix for the
        # per-group hex validation, but the prefix must be in 0-128.
        _ip="${_net%/*}"
        case "$_ip" in
            *:*)
                # IPv6: prefix must be 0-128.
                if [ "$_prefix" -gt 128 ]; then
                    printf 'level=error msg="IPv6 prefix out of range" network=%s prefix=%s\n' "$_net" "$_prefix" >&2
                    return 1
                fi
                ;;
            *.*.*.*)
                # IPv4 dotted-quad.
                if [ "$_prefix" -gt 32 ]; then
                    printf 'level=error msg="IPv4 prefix out of range" network=%s prefix=%s\n' "$_net" "$_prefix" >&2
                    return 1
                fi
                _oldIFS=$IFS; IFS=.
                # shellcheck disable=SC2086
                set -- $_ip
                IFS=$_oldIFS
                if [ $# -ne 4 ]; then
                    printf 'level=error msg="IPv4 address must have 4 octets" network=%s\n' "$_net" >&2
                    return 1
                fi
                for _oct; do
                    case "$_oct" in
                        ''|*[!0-9]*)
                            printf 'level=error msg="IPv4 octet not numeric" network=%s octet="%s"\n' "$_net" "$_oct" >&2
                            return 1
                            ;;
                    esac
                    if [ "$_oct" -gt 255 ]; then
                        printf 'level=error msg="IPv4 octet out of range" network=%s octet=%s\n' "$_net" "$_oct" >&2
                        return 1
                    fi
                done
                ;;
            *)
                printf 'level=error msg="unrecognized network format" network=%s\n' "$_net" >&2
                return 1
                ;;
        esac
    done
}

# validate_no_metacharacters VAR_NAME VALUE
#   Reject values containing spaces or shell metacharacters (; & | ` $).
#   Used for hostnames and similar values that should not contain shell-
#   significant characters.
validate_no_metacharacters() {
    case "$2" in
        *[[:space:]]*|*\;*|*\&*|*\|*|*\`*|*\$*)
            printf 'level=error msg="env var contains invalid characters" var=%s\n' "$1" >&2
            return 1
            ;;
    esac
}

# validate_tls_level VALUE
#   Validate against known Postfix smtp_tls_security_level values.
validate_tls_level() {
    case "$1" in
        none|may|encrypt|dane|dane-only|fingerprint|verify|secure) ;;
        *)
            printf 'level=error msg="invalid TLS security level" value="%s"\n' "$1" >&2
            return 1
            ;;
    esac
}

# validate_spec_format SPEC
#   Validate container:dbname:user format (exactly 2 colons).
#   Returns 0 on valid format, 1 on invalid.
validate_spec_format() {
    _colons=$(printf '%s' "$1" | tr -cd ':')
    if [ "${#_colons}" -ne 2 ]; then
        printf 'level=error msg="invalid spec format" spec="%s"\n' "$1" >&2
        return 1
    fi
}
