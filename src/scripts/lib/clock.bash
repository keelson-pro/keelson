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
# costs nothing. EPOCHREALTIME renders with the locale's decimal point, so
# both separators are accepted.
#
# Public API (results land in globals; a command substitution would fork and
# defeat the point):
#   clock_read              -> CLOCK_NOW_US
#   clock_parse <text>      -> CLOCK_PARSED_US
#   clock_format <micros>   -> CLOCK_TEXT

CLOCK_NOW_US=0
CLOCK_PARSED_US=0
CLOCK_TEXT=

# clock_parse <decimal-seconds>
# Accepts "<secs>", "<secs>.<frac>" or "<secs>,<frac>". A fraction shorter
# than six digits is scaled up rather than read as microseconds, one longer
# is truncated.
clock_parse() {
    local t=$1 secs frac
    secs=${t%%[.,]*}
    frac=${t#*[.,]}
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

# clock_format <micros>
# Sets CLOCK_TEXT to "<secs>.<six-digit-fraction>", which is what a stamp
# looks like on disk: an obvious Unix timestamp, nothing rounded away.
clock_format() {
    printf -v CLOCK_TEXT '%d.%06d' $(( $1 / 1000000 )) $(( $1 % 1000000 ))
}
