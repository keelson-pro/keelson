# Microsecond Unix time, without forking.
# Sourced; not directly executable.
#
# Everything here works in integer microseconds because bash has no floating
# point. Whole seconds are not good enough for either caller:
#
#   The controller loop times its own cycle. Two whole-second reads either
#   side of 0.4s of work differ by 0 or 1 depending only on where the second
#   boundary fell, so at the default one-second tick roughly half the fast
#   ticks would be misread as overruns, skip their sleep, and spin.
#
#   The heartbeat is written by the loop and read by keelson-probe. Comparing
#   two truncated stamps gives floor(a) - floor(b), which is within one whole
#   second of the truth in either direction. On a five-second liveness budget
#   that is a twenty percent error, and it lands on both sides: a probe can
#   call a fresh heartbeat stale, or a stale one fresh.
#
# Reads bash 5's EPOCHREALTIME rather than forking date, so the hot path
# costs nothing. EPOCHREALTIME renders with the locale's decimal point, which
# is a dot because the image sets LC_ALL=C and validate_config enforces it.
#
# Public API (results land in globals; a command substitution would fork and
# defeat the point):
#   clock_read              -> CLOCK_NOW_US
#   clock_parse <text>      -> CLOCK_PARSED_US
#   clock_format <micros>   -> CLOCK_TEXT

CLOCK_NOW_US=0
CLOCK_PARSED_US=0
CLOCK_TEXT=
CLOCK_DURATION=0

# clock_parse <decimal-seconds>
# Accepts "<secs>" or "<secs>.<frac>". A fraction shorter than six digits is
# scaled up rather than read as microseconds, one longer is truncated.
clock_parse() {
    local t=$1 secs frac
    secs=${t%%.*}
    frac=${t#*.}
    [ "$frac" = "$t" ] && frac=0
    frac="${frac}000000"
    # 10# so a leading zero is not read as octal.
    CLOCK_PARSED_US=$(( secs * 1000000 + 10#${frac:0:6} ))
}

# clock_read
# Sets CLOCK_NOW_US to the current Unix time in microseconds.
clock_read() {
    clock_parse "$EPOCHREALTIME"
    CLOCK_NOW_US=$CLOCK_PARSED_US
}

# clock_parse_duration <text>
# Sets CLOCK_DURATION to a whole number of seconds. Returns 1 on anything it
# cannot read, so a caller can fall back to its default and say why.
#
# Accepts, because Keelson maps poll-schedule onto keel.sh/pollSchedule and
# has to read what Keel users already have deployed:
#
#   45  30s  5m  2h  1d        bare, or a single unit
#   2h45m  1h30m10s            compound, as Go duration strings allow
#   1.5h  0.25h                fractional
#   @every 10m  @every5m       robfig/cron's descriptor, Keel's documented form
#   @hourly  @daily  @weekly   robfig/cron's fixed-length predefines
#
# Units are ns/us/ms/s/m/h as Go has them, plus d, which Go does not; a Keel
# user will never have written it, and it reads better than 24h.
#
# Accumulated in milliseconds and rounded to seconds at the end, half up, so
# 1.7s is 2s rather than 1s and 500ms is 1s rather than nothing. ns and us
# parse but are below the resolution this keeps.
#
# A duration under half a second yields 0, reported as a successful parse.
# That is deliberate: "I cannot read this" and "that is faster than I go" are
# different problems with different fixes, so the caller decides what to do
# about a zero rather than having a floor imposed here.
#
# Rejects @monthly, @yearly and raw cron expressions: those are calendar
# positions rather than durations, and honouring them would mean a cron
# implementation to serve the form Keel's own docs treat as the alternative
# to the recommended one.
#
# Fractions are scaled by the fraction's own digit count, which keeps this
# integer-only and fork-free. It runs once per workload per pass, so a fork
# here would be a fork per workload per pass.
clock_parse_duration() {
    local text=$1 rest num frac unit mult total=0 scale i matched=0
    [ -n "$text" ] || return 1

    case "$text" in
        '@every'*)
            rest=${text#@every}
            # Optional whitespace, as robfig accepts either.
            rest=${rest# }
            rest=${rest#	}
            ;;
        '@hourly') CLOCK_DURATION=3600;   return 0 ;;
        '@daily'|'@midnight') CLOCK_DURATION=86400; return 0 ;;
        '@weekly') CLOCK_DURATION=604800; return 0 ;;
        '@'*)      return 1 ;;
        *)         rest=$text ;;
    esac
    [ -n "$rest" ] || return 1

    while [ -n "$rest" ]; do
        num=${rest%%[!0-9]*}
        [ -n "$num" ] || return 1
        rest=${rest#"$num"}

        frac=
        if [ "${rest#.}" != "$rest" ]; then
            rest=${rest#.}
            frac=${rest%%[!0-9]*}
            [ -n "$frac" ] || return 1
            rest=${rest#"$frac"}
        fi

        unit=${rest%%[!a-zA-Z]*}
        rest=${rest#"$unit"}
        # Milliseconds per unit; ns and us are below what we keep.
        case "$unit" in
            ns|NS|us|US) mult=0 ;;
            ms|MS)       mult=1 ;;
            ''|s|S)      mult=1000 ;;
            m|M)         mult=60000 ;;
            h|H)         mult=3600000 ;;
            d|D)         mult=86400000 ;;
            *)           return 1 ;;
        esac

        # 10# so "010s" is ten seconds rather than an octal surprise.
        total=$(( total + 10#$num * mult ))
        if [ -n "$frac" ]; then
            scale=1
            for (( i = 0; i < ${#frac}; i++ )); do
                scale=$(( scale * 10 ))
            done
            # + scale/2 rounds the fraction half up rather than flooring it.
            total=$(( total + (10#$frac * mult + scale / 2) / scale ))
        fi
        matched=1
    done

    [ "$matched" -eq 1 ] || return 1
    CLOCK_DURATION=$(( (total + 500) / 1000 ))
    return 0
}

# clock_format <micros>
# Sets CLOCK_TEXT to "<secs>.<six-digit-fraction>", which is what a stamp
# looks like on disk: an obvious Unix timestamp, nothing rounded away.
clock_format() {
    printf -v CLOCK_TEXT '%d.%06d' $(( $1 / 1000000 )) $(( $1 % 1000000 ))
}
