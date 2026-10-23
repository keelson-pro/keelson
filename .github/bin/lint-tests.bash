#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Blocks bats assertions that can never fail, whatever bash runs them.
#
#   ! <cmd>             anywhere but the last line of a test. bash exempts a
#                       negated command from set -e, and bats only sees the
#                       status of the last one, so mid-test it checks nothing.
#   ! <cmd> || true     anywhere. Passes whatever <cmd> does.
#   [ ... ] || true     a test ([ ], [[ ]], (( )), test or an unredirected
#                       grep) followed by || true, || :, || exit 0,
#                       || return 0 (in a test; in a helper it is a
#                       guard), or an echo or printf (not redirected, >&2
#                       aside, or in a block with no return 1): passes
#                       whatever the test says.
#   [ a ] && [ b ]      anywhere but the last line: a failing [ a ] is
#                       exempt from set -e.
#   return 0            anywhere in a test but its last line, and a bare return.
#   diff, cmp, run !    count as assertions, as test and grep do, before || true.
# A test followed by || echo ... >file is left alone (the redirect is taken as
# deliberate), though it passes whatever the test says.
# The suite's assertion helpers (once, at_level, one_error, field_on,
# detail_whole, gone_ok) count as tests for the || true rules.
#   helper || ...       a helper holding two or more assertion lines, called
#                       on the left of || or &&, or under if or !, runs with
#                       errexit off: all but its last assertion check nothing.
#                       Fine when every assertion line in it returns on
#                       failure itself (|| return 1).
#   [ a ] && grep -q b  mid-test, an && list ending in an assertion: a failing
#                       first test skips it silently. Cleanup such as
#                       [ -n "$P" ] && kill "$P" is not an assertion.
#   [ a ] && true       mid-test, the same: && true or && : checks nothing.
#   once a && ...       mid-test, an assertion helper (one of the suite set,
#                       or any helper holding an assertion line) on the left
#                       of &&: a failing helper is exempt from set -e.
#   timeout N <test>    counts as the test it runs, and yq -e and jq -e count
#                       as assertions, before || true.
#   exit 0              anywhere in a test but its last line, and a bare exit
#                       or one whose status can be 0 (exit $?, exit 256):
#                       the rest goes unrun. The pinned bats reports that
#                       not ok, but older bats passed it; the rule keeps a
#                       test from depending on how bats takes an early exit.
#                       As a command anywhere on the line (after &&, in { },
#                       under builtin, command or time); not on the right of
#                       || or in a ( ) subshell (a case arm or a ( in ${ }
#                       is none), and exit 1 fails.
#   [ a = b ] &         a test sent to the background: its status is lost.
#                       A helper process launched there is not a test.
# A line continued with a backslash is also judged joined to the next for
# the || true rule, so "[ a ] \" then "|| true" is caught as on one line.
# A helper whose body is a subshell, f() ( ... ), is checked as one in braces.
# A | inside a quoted pattern is not a pipe, and a $( ... ) capture is not an
# assertion, whatever it holds.
#   set +e (or +eu...)  anywhere, setup included: carries into every test.
#   set +o errexit      the same, spelled out, after anything (; && then
#                       builtin command ...).
#   trap ... ERR        or a trap that exits or returns 0: can turn a
#                       failure into a pass ("trap - ERR", a reset, is fine).
#   eval '...set +e'    errexit off all the same.
#
# "! <cmd> || false" is fine anywhere: the false is what set -e sees.
# Heredoc bodies (the shims) are skipped, they are not test code, and so are
# the lines of a quoted string that spans lines (a bash -c script): it runs
# in a child. A test-local function, f() { or f() (, is its own body.
#
# Lints src/tests/*.bats and the helpers beside them, or the files given.
# Helper functions are checked as test bodies are: an assertion that cannot
# fail in a helper weakens every test that calls it. Runs from any CWD: resolves
# the repo root from this script's location.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ $# -eq 0 ]; then
    set -- src/tests/*.bats src/tests/*.bash
fi

# Helpers by what they hold. U: two or more assertion lines, not every one of
# them returning on failure itself: called with errexit off (on the left of ||
# or &&, under if or !), all but the last check nothing. A: any assertion line
# at all: on the left of && mid-test, a failing one fails nothing.
helper_kinds=$(awk '
FNR == 1 { name = ""; tag = "" }
tag != "" { t = $0; sub(/^[ \t]+/, "", t); if (t == tag) tag = ""; next }
/^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*[{(][ \t]*$/ {
    name = $0; sub(/[ \t]*\(.*$/, "", name); n = 0; u = 0; a = 0
    closer = ($0 ~ /\([ \t]*$/) ? "^\\)[ \t]*$" : "^}[ \t]*$"
    next
}
name != "" && $0 ~ closer { if (n >= 2 && u >= 1) print "U " name; if (a >= 1) print "A " name; name = ""; next }
name != "" {
    if (match($0, /(^|[^<])<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        tag = substr($0, RSTART, RLENGTH); sub(/^[^<]?<<-?[ \t]*/, "", tag); gsub(/[\047"]/, "", tag)
    }
    if ($0 ~ /^[ \t]*(\[|test[ \t]|grep[ \t]+-q|once[ \t]|at_level[ \t]|one_error|field_on[ \t]|detail_whole[ \t]|gone_ok)/) {
        a++
        if ($0 !~ /&&/) {
            n++
            if ($0 !~ /\|\|/) u++
        }
    }
}
' "$@" | sort -u)
unsafe_helpers=$(printf '%s\n' "$helper_kinds" | sed -n 's/^U //p' | tr '\n' ' ')
assert_helpers=$(printf '%s\n' "$helper_kinds" | sed -n 's/^A //p' | tr '\n' ' ')

awk -v unsafe="$unsafe_helpers" -v assert_helpers="$assert_helpers" '
function flag(file, line, text, why) {
    sub(/^[ \t]+/, "", text)
    printf "%s:%d: %s\n    %s\n", file, line, why, text
    bad++
}
FNR == 1 {
    if (str != "") flag(str_file, str_line, str_text, "a quoted string opened here never closes, so the lint cannot tell what follows it from the string")
    in_test = 0; in_teardown = 0; tag = ""; pending = 0; cont = ""; str = ""
}
# The line a finding is reported at: a continued line is reported where it
# starts.
{ at = FNR }
tag != "" {
    t = $0
    sub(/^[ \t]+/, "", t)
    if (t == tag) tag = ""
    next
}
# Inside a quoted string that spans lines: skipped to where it closes, and
# the rest of that line judged with the string as one word. A new test
# cannot start inside one: a string still open there was misread.
str != "" && /^@test / {
    flag(str_file, str_line, str_text, "a quoted string opened here never closes, so the lint cannot tell what follows it from the string")
    str = ""
}
str != "" {
    open_q = str
    str = qscan($0, str)
    if (str != "") next
    $0 = ((substr(open_q, 1, 1) == "d") ? "\"Q\"" : "\047Q\047") substr($0, close_at + 1)
}
# The line with quoted strings dropped: a set +e in a quoted bash -c script runs
# in a child, and one inside a test name is just words. Trap bodies are
# quoted, so traps are judged on the whole line.
{
    bare = $0
    gsub(/\047[^\047]*\047/, "", bare)
    gsub(/"[^"]*"/, "", bare)
}
# Turning errexit off anywhere in a .bats file, setup included, carries into
# every test body, where then no assertion can fail.
!/^[ \t]*#/ && bare ~ /(^|[;&|({ \t])(set[ \t]+([^;&|]*[ \t])?(\+[A-Za-z]*e|\+o[ \t]+errexit)|shopt[ \t]+(-u[ \t]+-o|-uo|-ou)[ \t]+errexit)/ {
    flag(FILENAME, FNR, $0, "errexit turned off: no assertion after this can fail; use set +u alone if set -u is the problem")
    next
}
!/^[ \t]*#/ && (/(^|[;&|({ \t])set[ \t]+[\047"]\+[A-Za-z]*e[A-Za-z]*[\047"]/ || /(^|[;&|({ \t])set[ \t]+\+o[ \t]+[\047"]errexit[\047"]/) {
    flag(FILENAME, FNR, $0, "errexit turned off: no assertion after this can fail")
    next
}
!/^[ \t]*#/ && /(^|[;&|({ \t])eval[ \t].*set[ \t]+\+[A-Za-z]*e/ {
    flag(FILENAME, FNR, $0, "errexit turned off through eval: no assertion after this can fail")
    next
}
# "trap - ERR" resets a trap: it turns nothing into a pass.
!/^[ \t]*#/ && bare ~ /(^|[;&|({ \t])trap[ \t]/ && bare !~ /trap[ \t]+-[ \t]/ && (/ERR/ || /(exit|return)[ \t]+0/) {
    flag(FILENAME, FNR, $0, "a trap like this can turn a failure into a pass")
    next
}
# qscan(s, st): the quoting state at the end of s, begun in st: "" outside
# any quote, else a stack of contexts, innermost last (s single, a ANSI-C
# $\047 \047, d double, c a $( ) inside a double-quoted string, p a ( within
# that, b a backquote). Quotes inside a capture in a string are their own, as
# bash reads them: an apostrophe in the inner string of x="$(echo "...")"
# opens nothing. A $( ) outside any string needs no tracking: the quotes in
# it read as they would outside it. close_at is where the stack first
# emptied. A # starting a word outside quotes ends the line. qmask is s up
# to there with every quoted or escaped character a Q, the same length, so a
# position in it is the same position in s.
function qscan(s, st,    i, n, c, top, j, pre, chunk) {
    close_at = 0
    qmask = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        j = i
        pre = st
        c = substr(s, i, 1)
        top = substr(st, length(st), 1)
        if (top == "s") {
            if (c == "\047") st = substr(st, 1, length(st) - 1)
        } else if (top == "a" || top == "d" || top == "b") {
            if (c == "\\") i++
            else if ((top == "a" && c == "\047") || (top == "d" && c == "\"") || (top == "b" && c == "`")) st = substr(st, 1, length(st) - 1)
            else if (top == "d" && c == "$" && substr(s, i + 1, 1) == "(") { st = st "c"; i++ }
            else if (top == "d" && c == "`") st = st "b"
            else if (top == "b" && c == "\"") st = st "d"
            else if (top == "b" && c == "\047") st = st "s"
        } else if (c == "\\") {
            i++
        } else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;(]/)) {
            break
        } else if (c == "\047") {
            st = st ((i > 1 && substr(s, i - 1, 1) == "$") ? "a" : "s")
        } else if (c == "\"") {
            st = st "d"
        } else if (top == "c" || top == "p") {
            if (c == "$" && substr(s, i + 1, 1) == "(") { st = st "c"; i++ }
            else if (c == "(") st = st "p"
            else if (c == ")") st = substr(st, 1, length(st) - 1)
            else if (c == "`") st = st "b"
        }
        if (st == "" && !close_at && top != "") close_at = i
        chunk = substr(s, j, i - j + 1)
        if (pre != "" || st != "" || c == "\\") gsub(/./, "Q", chunk)
        qmask = qmask chunk
    }
    return st
}
# runof(c, n): c n times.
function runof(c, n,    r) {
    r = ""
    while (n-- > 0) r = r c
    return r
}
# cword(s, i, w): the word w starts at i in s, whole.
function cword(s, i, w) {
    return substr(s, i, length(w)) == w && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|()<>]/) \
        && substr(s, i + length(w), 1) ~ /^[ \t;&|()<>]?$/
}
# cmask(line, cst): the qscan mask of line, with a ${ } expansion all Q (a
# ( or ) in ${s//(/_} is text), and in cm_arms an A at each ( or ) that
# belongs to a case pattern rather than a subshell: the ) ending a case arm
# pattern, an optional ( before it, and any pair inside it. cst is the case
# state at the line start and cm_case at its end, a stack, innermost last:
# w (after case, before its word), i (before in), p (a pattern next), b (the
# body of an arm). case and esac count only as the command they are.
function cmask(line, cst,    s, i, n, c, top, k, bd, pp, lead, pre) {
    qscan(line, "")
    s = qmask
    n = length(s)
    for (i = 1; i <= n; i++) {
        if (substr(s, i, 2) != "${") continue
        bd = 0
        for (k = i + 1; k <= n; k++) {
            c = substr(s, k, 1)
            if (c == "{") bd++
            else if (c == "}" && --bd == 0) break
        }
        if (k > n) k = n
        s = substr(s, 1, i - 1) runof("Q", k - i + 1) substr(s, k + 1)
        i = k
    }
    cm_arms = ""
    pp = 0; lead = 1
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        top = substr(cst, length(cst), 1)
        if (c ~ /[ \t]/) continue
        if (top == "w" || top == "i") {
            if (top == "i" && cword(s, i, "in")) { cst = substr(cst, 1, length(cst) - 1) "p"; lead = 1; pp = 0; i++; continue }
            if (top == "w") cst = substr(cst, 1, length(cst) - 1) "i"
            while (i < n && substr(s, i + 1, 1) !~ /[ \t;&|()<>]/) i++
            continue
        }
        if (top == "p") {
            if (lead && cword(s, i, "esac")) { cst = substr(cst, 1, length(cst) - 1); i += 3; continue }
            if (c == "(") { if (!lead) pp++; cm_arms = cm_arms runof(" ", i - 1 - length(cm_arms)) "A"; lead = 0; continue }
            if (c == ")") {
                cm_arms = cm_arms runof(" ", i - 1 - length(cm_arms)) "A"
                if (pp > 0) pp--
                else cst = substr(cst, 1, length(cst) - 1) "b"
                continue
            }
            lead = 0
            continue
        }
        if (top == "b" && c == ";" && substr(s, i + 1, 1) ~ /[;&]/) {
            cst = substr(cst, 1, length(cst) - 1) "p"; lead = 1; pp = 0
            i++
            if (substr(s, i + 1, 1) == "&") i++
            continue
        }
        if (c != "c" && c != "e") continue
        if (!cword(s, i, "case") && !(top == "b" && cword(s, i, "esac"))) continue
        pre = substr(s, 1, i - 1)
        sub(/[ \t]+$/, "", pre)
        if (pre != "" && pre !~ /([;&|({!)]|(^|[ \t;&|({)])(then|do|else|elif|if|while|until|time))$/) continue
        if (c == "c") cst = cst "w"
        else cst = substr(cst, 1, length(cst) - 1)
        i += 3
    }
    cm_case = cst
    return s
}
# exit_mid(line, depth, cst): the line runs exit as a command of the test
# itself, with no status or one that can be 0 (a literal that is 0 mod 256,
# as 256 is): first, after ; && { then do else or a case arm, through
# builtin, command, time (a keyword: time exit 0 exits all the same) or
# NAME=value and NAME+=value prefixes. Not on the right of || (a failure
# path), not inside ( ) or $( ) (a subshell), and not in a function the line
# defines. <depth> is how many ( ) or $( ) opened on earlier lines are still
# open at its start, and <cst> the case state there (cmask). Read on the
# cmask mask, so quotes are taken in context; a quoted status ("2") is its
# literal with the quotes removed.
function exit_mid(line, depth, cst,    s, i, n, c, prev, arg, num, at_num) {
    if (line ~ /^[ \t]*(function[ \t]+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))/) return 0
    s = cmask(line, cst)
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (substr(cm_arms, i, 1) == "A") continue
        if (c == "(") { depth++; continue }
        if (c == ")") { if (depth > 0) depth--; continue }
        if (depth > 0 || substr(s, i, 4) != "exit" || substr(s, i + 4, 1) !~ /^[ \t;&|}]?$/) continue
        prev = substr(s, 1, i - 1)
        sub(/[ \t]+$/, "", prev)
        while (prev ~ /(^|[ \t;&{])(builtin|command|time([ \t]+-p)?|[A-Za-z_][A-Za-z0-9_]*[+]?=[^ \t;&|{}()]*)$/) {
            sub(/(builtin|command|time([ \t]+-p)?|[A-Za-z_][A-Za-z0-9_]*[+]?=[^ \t;&|{}()]*)$/, "", prev)
            sub(/[ \t]+$/, "", prev)
        }
        if (prev != "" && prev !~ /(;|&|\{|\)|(^|[ \t;])(then|do|else))$/) continue
        arg = substr(s, i + 4)
        if (match(arg, /^[ \t]+[^ \t;&|}]+/)) {
            at_num = i + 4
            while (substr(s, at_num, 1) ~ /[ \t]/) at_num++
            num = substr(line, at_num, i + 4 + RLENGTH - at_num)
            gsub(/["\047]/, "", num)
            if (num ~ /^-?[0-9]+$/ && (num + 0) % 256 != 0) continue
        }
        return 1
    }
    return 0
}
# paren_depth(line, depth, cst): <depth> after the ( ) and $( ) the line
# opens and closes outside quotes, ${ } and case patterns, and in cm_case
# the case state after it, begun in <cst>. A ) the case state cannot place
# never takes it below 0.
function paren_depth(line, depth, cst,    s, i, n, c) {
    s = cmask(line, cst)
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (substr(cm_arms, i, 1) == "A") continue
        if (c == "(") depth++
        else if (c == ")" && depth > 0) depth--
    }
    return depth
}
# A heredoc starts the same way inside a test or out: in a helper, its body
# (a shim, say) is not test code either.
function heredoc(line,    seg) {
    # Only a real one: not in a comment, and not inside a quoted string,
    # where "<<EOF" is just text and would skip the rest of the file. The
    # quotes around a tag go first, so stripping strings keeps the tag.
    if (line ~ /^[ \t]*#/) return
    while (match(line, /<<-?[ \t]*[\047"][A-Za-z_][A-Za-z0-9_]*[\047"]/)) {
        seg = substr(line, RSTART, RLENGTH)
        gsub(/[\047"]/, "", seg)
        line = substr(line, 1, RSTART - 1) seg substr(line, RSTART + RLENGTH)
    }
    gsub(/\047[^\047]*\047/, "", line)
    gsub(/"[^"]*"/, "", line)
    sub(/[ \t]#.*$/, "", line)
    # A here-string (<<<) is not a heredoc: nothing follows it to skip.
    if (match(line, /(^|[^<])<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
        tag = substr(line, RSTART, RLENGTH)
        sub(/^[^<]?<<-?[ \t]*/, "", tag)
    }
}
# unsafe_call(line): the line calls one of the unsafe helpers on the left of
# || or &&, or under if or !.
function unsafe_call(line,    n, names, i, h) {
    if (unsafe == "") return 0
    n = split(unsafe, names, " ")
    for (i = 1; i <= n; i++) {
        h = names[i]
        if (h == "") continue
        if (line ~ ("(^|[;{(][ \t]*|^[ \t]*)(if[ \t]+|![ \t]+|while[ \t]+|until[ \t]+)" h "([ \t]|;|$)")) return 1
        if (line ~ ("(^|[;{(][ \t]*|^[ \t]*|(\\|\\||&&)[ \t]*)" h "([ \t][^|&;]*)?[ \t]*(\\|\\||&&)")) return 1
        if (line ~ ("(\\|\\||&&)[ \t]*![ \t]*" h "([ \t]|;|$)")) return 1
    }
    return 0
}
# amp_asserts(line): an && list whose last command is itself an assertion,
# so a failing earlier test skips it without failing anything.
function amp_asserts(line,    seg) {
    seg = line
    gsub(/\047[^\047]*\047/, "Q", seg)
    gsub(/"[^"]*"/, "Q", seg)
    if (seg !~ /^[ \t]*(\[|test[ \t]|grep[ \t])/) return 0
    sub(/^.*&&[ \t]*/, "", seg)
    # && true and && : add nothing: the test before them is all there is.
    return seg ~ /^(\[|test[ \t]|grep[ \t]+-q|once[ \t]|at_level[ \t]|one_error|field_on[ \t]|detail_whole[ \t]|gone_ok|(true|:)[ \t]*$)/
}
# amp_helper(line): an assertion helper, of the suite set or one found holding
# an assertion line, starts a command on the left of &&: when it fails, the
# && list fails with errexit off, and nothing does.
function amp_helper(line,    seg, n, names, i, h) {
    seg = line
    gsub(/\\"/, "", seg)
    gsub(/\047[^\047]*\047/, "Q", seg)
    gsub(/"[^"]*"/, "Q", seg)
    while (match(seg, /\$\([^()]*\)/)) seg = substr(seg, 1, RSTART - 1) "CAP" substr(seg, RSTART + RLENGTH)
    n = split("once at_level one_error field_on detail_whole gone_ok " assert_helpers, names, " ")
    for (i = 1; i <= n; i++) {
        h = names[i]
        if (h == "") continue
        if (seg ~ ("(^[ \t]*|[;{(][ \t]*|&&[ \t]*)" h "([ \t][^|&;]*)?[ \t]*&&")) return 1
    }
    return 0
}
# is_assertion(cmd, bracket): one command, quotes and captures hidden, is a
# test (bracket is cmd without a trailing redirect). The assertion helpers of
# this suite count as tests too: one followed by || true asserts nothing either.
function is_assertion(cmd, bracket) {
    return (bracket ~ /^(\[|\(\()/ && bracket ~ /(\]|\)\))$/) || (cmd !~ />/ && cmd ~ /^(test|grep|diff|cmp)[ \t]/) \
        || cmd ~ /^run[ \t]+![ \t]/ \
        || (cmd !~ />/ && cmd ~ /^(yq|jq)[ \t]/ && cmd ~ /[ \t](-[A-Za-z]*e[A-Za-z]*|--exit-status)([ \t]|$)/) \
        || cmd ~ /^(once|at_level|one_error|field_on|detail_whole|gone_ok)([ \t]|$)/
}
# bg_asserts(line): the line sends a test to the background with a trailing
# &, where its status is lost: the last command of the list is one, or the
# list is a test alone or followed by a || that fails (false, return or exit
# 1, a block that returns). [ -n "$P" ] && kill "$P" & and ( exec true ) &
# launch something; they test nothing.
function bg_asserts(line,    seg, k, ch, cmd, first, tail_or) {
    seg = line
    if (seg !~ /(^|[^&])&[ \t]*$/) return 0
    sub(/[ \t]*&[ \t]*$/, "", seg)
    gsub(/\\"/, "", seg)
    gsub(/\047[^\047]*\047/, "\047Q\047", seg)
    gsub(/"[^"]*"/, "\"Q\"", seg)
    while (match(seg, /\$\([^()]*\)/)) seg = substr(seg, 1, RSTART - 1) "CAP" substr(seg, RSTART + RLENGTH)
    if (match(seg, /\[\[.*\]\]/)) {
        cmd = substr(seg, RSTART, RLENGTH)
        gsub(/\|/, "#", cmd)
        seg = substr(seg, 1, RSTART - 1) cmd substr(seg, RSTART + RLENGTH)
    }
    sub(/^[ \t]*[{(][ \t]+/, "", seg)
    sub(/([ \t]*;[ \t]*\}|[ \t]+\))[ \t]*$/, "", seg)
    gsub(/[0-9]*>[ \t]*\/dev\/null/, "", seg)
    gsub(/[0-9]?>&[0-9]/, "", seg)
    sub(/[ \t]+$/, "", seg)
    cmd = seg
    for (k = length(cmd); k > 0; k--) {
        ch = substr(cmd, k, 1)
        if (ch == ";" || ch == "|" || (ch == "&" && substr(cmd, k - 1, 1) == "&")) { cmd = substr(cmd, k + 1); break }
    }
    sub(/^[ \t]*((command|builtin)[ \t]+)*/, "", cmd)
    sub(/^[{(][ \t]+/, "", cmd)
    sub(/([ \t]*;[ \t]*\}|[ \t]+\))$/, "", cmd)
    if (is_assertion(cmd, cmd)) return 1
    if (seg ~ /&&/) return 0
    first = seg
    sub(/[ \t]*\|\|.*$/, "", first)
    sub(/^[ \t]*((command|builtin)[ \t]+)*/, "", first)
    if (!is_assertion(first, first)) return 0
    if (seg !~ /\|\|/) return 1
    tail_or = seg
    sub(/^[^|]*\|\|[ \t]*/, "", tail_or)
    return tail_or ~ /^(false|(return|exit)[ \t]+[1-9])/ || (tail_or ~ /^\{/ && tail_or ~ /(return|exit)[ \t]+[1-9]|false/)
}
# check(text, mid): the rules for one line of a test or helper body. With
# mid set, a line that is fine last but not mid-body is held until the next.
function check(text, mid,    line, plain, before, after, asserts, last, bracket, split_at, k, ch, opens, closes, head, tail_cmd, inner) {
    # The line without a trailing comment, ; or >&2, and the command before
    # its last ||: what decides whether a failure can still fail the test.
    line = text
    sub(/[ \t]+#[^\047"]*$/, "", line)
    sub(/[ \t]*;[ \t]*$/, "", line)
    if (bg_asserts(line)) {
        flag(FILENAME, at, text, "a test sent to the background with & passes whatever it says; run it in the foreground")
        return
    }
    # The end of a one-line if or loop, or a trailing &, is not part of the
    # command the || hangs off.
    sub(/[ \t]*(;[ \t]*(fi|done)|&)[ \t]*$/, "", line)
    sub(/^[ \t]*(if|while|until|for)[ \t].*;[ \t]*(then|do)[ \t]+/, "", line)
    # A one-line case arm: the command between the pattern and its ;;.
    if (line ~ /^[ \t]*case[ \t].*[ \t]in[ \t]/) {
        sub(/^[ \t]*case[ \t].*[ \t]in[ \t]+[^)]*\)[ \t]*/, "", line)
        sub(/[ \t]*;;[ \t]*(esac)?[ \t]*$/, "", line)
    }
    plain = line
    gsub(/[0-9]?>&[0-9]/, "", plain)
    before = ""; after = ""
    if (match(line, /\|\|[^|]*$/)) {
        before = substr(line, 1, RSTART - 1)
        after = substr(line, RSTART + 2)
    }
    # The command the || hangs off: the last of a pipe, && list or ; list,
    # with redirects to /dev/null or another descriptor set aside, and
    # command or builtin in front looked through. A test, (( )) or grep
    # there asserts; one redirected into a file is filtering, not asserting.
    last = before
    # "&& true" adds nothing to what came before it.
    sub(/[ \t]*&&[ \t]*(true|:)[ \t]*$/, "", last)
    # Redirects set aside first, so a group still ends in its brace.
    gsub(/[0-9]*>[ \t]*\/dev\/null/, "", last)
    gsub(/[0-9]?>&[0-9]/, "", last)
    sub(/[ \t]+$/, "", last)
    # A test grouped in { ...; } is unwrapped first: its ; is not a list.
    if (last ~ /^[ \t]*\{.*;[ \t]*\}[ \t]*$/) {
        sub(/^[ \t]*\{[ \t]*/, "", last)
        sub(/[ \t]*;[ \t]*\}[ \t]*$/, "", last)
    }
    gsub(/[0-9]*>[ \t]*\/dev\/null/, "", last)
    gsub(/[0-9]?>&[0-9]/, "", last)
    # A | inside a quoted string is text, and a $( ... ) capture is one word
    # whatever it holds: both hidden from the split below.
    gsub(/\\"/, "", last)
    gsub(/\047[^\047]*\047/, "\047Q\047", last)
    gsub(/"[^"]*"/, "\"Q\"", last)
    while (match(last, /\$\([^()]*\)/)) last = substr(last, 1, RSTART - 1) "CAP" substr(last, RSTART + RLENGTH)
    # Inside [[ ]] a | is a regex alternation, not a pipe: hidden from the
    # split below.
    if (match(last, /\[\[.*\]\]/)) {
        inner = substr(last, RSTART, RLENGTH)
        gsub(/\|/, "#", inner)
        last = substr(last, 1, RSTART - 1) inner substr(last, RSTART + RLENGTH)
    }
    split_at = 0
    for (k = length(last); k > 0; k--) {
        ch = substr(last, k, 1)
        if (ch == ";" || (ch == "|" && substr(last, k - 1, 1) != "|" && substr(last, k + 1, 1) != "|") || (ch == "&" && substr(last, k - 1, 1) == "&")) { split_at = k; break }
    }
    last = substr(last, split_at + 1)
    sub(/^[ \t]*((command|builtin)[ \t]+)*/, "", last)
    sub(/[ \t]+$/, "", last)
    # A test grouped in { ...; } or ( ... ) is still the test.
    sub(/^[{(][ \t]+/, "", last)
    sub(/([ \t]*;[ \t]*\}|[ \t]+\))$/, "", last)
    # timeout N <cmd> is <cmd> with a time limit: judged as <cmd>.
    sub(/^timeout[ \t]+((-[ks]|--kill-after|--signal)[ \t]+[^ \t]+[ \t]+|-[^ \t]+[ \t]+)*[0-9.]+[smhd]?[ \t]+/, "", last)
    # A test prints nothing, so a redirect after one changes nothing
    # either; on grep it is filtering into a file. (No apostrophes in this
    # program: it is one single-quoted shell word.)
    bracket = last
    sub(/[ \t]*[0-9]*>>?[ \t]*[^ \t]+$/, "", bracket)
    asserts = is_assertion(last, bracket)
    # What follows the ||, without a redirect or the ) of a subshell.
    # The ) only when this line opened it: one closing a $( ... ) begun on
    # an earlier line ends a capture, where || true is deliberate.
    gsub(/[ \t]*[0-9]*>&?[^ \t)]+/, "", after)
    opens = gsub(/\(/, "(", line); closes = gsub(/\)/, ")", line)
    if (opens >= closes) sub(/[ \t]*\)[ \t]*$/, "", after)
    sub(/^[ \t]*((builtin|command)[ \t]+)+/, "", after)
    # Joined continuation lines are judged for || true alone: the other
    # rules have seen each line already.
    if (only_true) {
        if (asserts && (after ~ /^[ \t]*(\{[ \t]*)?(true|:([ \t].*)?|exit[ \t]+0|skip([ \t].*)?)[ \t]*(;[ \t]*\})?[ \t]*$/ || after ~ /^[ \t]*(true|:)[ \t]*;/))
            flag(FILENAME, at, text, "an assertion followed by || true passes whatever it says")
        return
    }
    # "|| false || true": judged on the last ||, the false before it counts
    # for nothing.
    if (before ~ /\|\|[ \t]*false[ \t]*$/ && after ~ /^[ \t]*(true|:)[ \t]*$/) {
        flag(FILENAME, at, text, "|| false || true passes whatever the test says")
        return
    }
    # A test or grep piped onward: bats sets no pipefail, so the status is
    # the last command of the pipe.
    # Judged with quoted strings dropped (a | inside one is text), and only
    # when the last command of the pipe is not itself an assertion and its
    # output is not going into a file (that is preparing data).
    head = line
    gsub(/\\"/, "", head)
    gsub(/\047[^\047]*\047/, "", head)
    gsub(/"[^"]*"/, "", head)
    gsub(/[0-9]*>[ \t]*\/dev\/null|[0-9]?>&[0-9]/, "", head)
    sub(/^[ \t]*((command|builtin)[ \t]+)*/, "", head)
    tail_cmd = head
    sub(/\|\|.*$/, "", tail_cmd)
    sub(/^.*[^|]\|[ \t]*/, "", tail_cmd)
    # A [ ] test pipes onward only right after its closing bracket: a |
    # inside it is a regex group or a capture. A line holding a $( ... ) is
    # left alone: its pipes belong to the capture.
    if (((head ~ /^\[/ && head ~ /\][ \t]*\|[^|]/) || (head ~ /^(test|grep)[ \t]/ && match(head, /[^|]\|[^|]/) && substr(head, 1, RSTART) !~ /\$\(/)) \
            && tail_cmd !~ /^(\[|test[ \t]|grep[ \t])/ && head !~ />/ && line !~ /\$\(/) {
        flag(FILENAME, at, text, "an assertion piped onward passes whatever it says (no pipefail in bats)")
        return
    }
    # A helper of several assertions run with errexit off.
    # Judged on the raw line: the one-line if wrapper is stripped from line.
    if (unsafe_call(text)) {
        flag(FILENAME, at, text, "a helper of several assertions called with errexit off (left of || or &&, or under if or !) checks only its last; end each of its assertions with || return 1, or call it bare")
        return
    }
    if (line ~ /^[ \t]*! / && after ~ /^[ \t]*true[ \t]*$/) {
        flag(FILENAME, at, text, "\"! <cmd> || true\" passes whatever <cmd> does")
    } else if (asserts && (after ~ /^[ \t]*(\{[ \t]*)?(true|:([ \t].*)?|exit[ \t]+0|skip([ \t].*)?)[ \t]*(;[ \t]*\})?[ \t]*$/ || after ~ /^[ \t]*(true|:)[ \t]*;/)) {
        flag(FILENAME, at, text, "an assertion followed by || true passes whatever it says")
    } else if (asserts && kind == "test" && after ~ /^[ \t]*(\{[ \t]*)?return[ \t]+0[ \t]*(;[ \t]*\})?[ \t]*$/) {
        # In a helper, "|| return 0" is a guard; in a test it is a pass.
        flag(FILENAME, at, text, "an assertion followed by || return 0 passes whatever it says")
    } else if (asserts && after ~ /^[ \t]*(\{[ \t]*)?cat[ \t]/ && after !~ /(return|exit)[ \t]+[1-9]|false/) {
        flag(FILENAME, at, text, "an assertion followed by || cat passes whatever it says; use || { cat ...; return 1; }")
    } else if (asserts && after ~ /^[ \t]*(echo|printf)[ \t]/ && plain !~ />/) {
        flag(FILENAME, at, text, "an assertion followed by || echo passes whatever it says; use || { echo ...; return 1; }")
    } else if (asserts && after ~ /^[ \t]*\{[ \t]*(echo|printf)[ \t]/ && after !~ /(return|exit)[ \t]+[1-9]|false/ && (kind == "test" || after !~ /return|exit/)) {
        flag(FILENAME, at, text, "an assertion followed by || { echo ...; } passes whatever it says; end the block with return 1")
    } else if (mid && line ~ /(^[ \t]*|;[ \t]*|(\|\||&&)[ \t]*)! / && after !~ /^[ \t]*false[ \t]*$/) {
        pending = 1; pending_line = at; pending_text = text
        pending_why = "negated command is not the last line of its test, so it asserts nothing; use: if <cmd>; then false; fi"
    } else if (mid && kind == "test" && nested == 0 && line ~ /^[ \t]*return([ \t]+0)?[ \t]*$/) {
        # An early return 0, or a bare return after a passing command, passes
        # the test with whatever follows unrun.
        pending = 1; pending_line = at; pending_text = text
        pending_why = "return 0 before the end of a test passes it without running the rest"
    } else if (mid && kind == "test" && nested == 0 && exit_mid(text, sub_depth, sub_case)) {
        pending = 1; pending_line = at; pending_text = text
        pending_why = "exit 0 (or a bare exit, or exit $?) before the end of a test ends it with the rest unrun, and whether that passes depends on the bats version (older ones passed it)"
    } else if (mid && line ~ /&&/ && line !~ /\|\|/ && (line ~ /(\]|\)\))[ \t]*$/ || amp_asserts(line))) {
        # bash exempts all but the last of an && list from set -e.
        pending = 1; pending_line = at; pending_text = text
        pending_why = "a test before && is not the last line of its test, so when it fails nothing does; put each test on its own line"
    } else if (mid && line ~ /&&/ && line !~ /\|\|/ && amp_helper(line)) {
        pending = 1; pending_line = at; pending_text = text
        pending_why = "an assertion helper before && is not the last line of its test, so when it fails nothing does; put each call on its own line"
    }
}
# Where a helper starts: f() {, f () { or function f {, alone on its line.
# One on a single line has its body checked there and then.
# A test written on one line has its body checked there and then.
/^@test .*\{.*\}[ \t]*$/ {
    body = $0
    sub(/^@test [^{]*\{[ \t]*/, "", body)
    sub(/[ \t]*;?[ \t]*\}[ \t]*$/, "", body)
    kind = "test"
    check(body, 0)
    next
}
/^@test / { in_test = 1; kind = "test"; closer = "}"; pending = 0; nested = 0; sub_depth = 0; sub_case = ""; next }
# teardown and teardown_file clean up after a test: a guard there that
# tolerates failure is the point, not an assertion.
/^(function[ \t]+)?teardown(_file)?[ \t]*(\(\))?[ \t]*\{[ \t]*$/ { in_teardown = 1; next }
in_teardown && /^}[ \t]*$/ { in_teardown = 0; next }
in_teardown { heredoc($0); next }
# A helper whose body is a subshell, f() (, ends at a ) alone on its line.
/^(function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))[ \t]*[{(][ \t]*$/ {
    in_test = 1; kind = "helper"; pending = 0
    closer = ($0 ~ /\([ \t]*$/) ? ")" : "}"
    next
}
!in_test && /^(function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))[ \t]*\{.*\}[ \t]*$/ {
    body = $0
    sub(/^[^{]*\{[ \t]*/, "", body)
    sub(/[ \t]*;?[ \t]*\}[ \t]*$/, "", body)
    kind = "helper"
    check(body, 0)
    next
}
!in_test && /^(function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))[ \t]*\(.*\)[ \t]*$/ {
    body = $0
    sub(/^[^(]*\([ \t]*\)[ \t]*\([ \t]*/, "", body)
    sub(/^function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*/, "", body)
    sub(/[ \t]*;?[ \t]*\)[ \t]*$/, "", body)
    kind = "helper"
    check(body, 0)
    next
}
in_test && closer == "}" && /^}[ \t]*$/ { in_test = 0; pending = 0; cont = ""; next }
in_test && closer == ")" && /^\)[ \t]*$/ { in_test = 0; pending = 0; cont = ""; next }
!in_test { heredoc($0); next }
/^[ \t]*$/ || /^[ \t]*#/ { next }
# A function defined inside a test: its return 0 returns from it, not from
# the test. Tracked by its indented opening and closing lines.
# One with a subshell body, f() (, ends at its own ) the same way.
in_test && /^[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*[{(][ \t]*$/ {
    nested++
    nest_close[nested] = ($0 ~ /\([ \t]*$/) ? ")" : "}"
}
in_test && nested > 0 && nest_close[nested] == "}" && /^[ \t]+\}[ \t]*$/ { nested--; next }
in_test && nested > 0 && nest_close[nested] == ")" && /^[ \t]+\)[ \t]*$/ { nested--; next }
{
    if (pending) {
        flag(FILENAME, pending_line, pending_text, pending_why)
        pending = 0
    }
    check($0, 1)
    # A ( ) subshell or $( ) capture left open runs on into the lines
    # below: an exit there leaves only it. The ( that opens a test-local
    # f() ( belongs to that function, and its ) is never seen here.
    if ($0 !~ /^[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\([ \t]*$/) {
        sub_depth = paren_depth($0, sub_depth, sub_case)
        sub_case = cm_case
    }
    heredoc($0)
    # A quoted string left open runs on into the lines below, after the
    # body of any heredoc the line starts ("$(cat <<EOF ... EOF then )").
    str = qscan($0, "")
    if (str != "") { str_file = FILENAME; str_line = FNR; str_text = $0 }
    # A line ending in a backslash is also judged joined to the lines it
    # continues onto, for || true alone: "[ a ] \" then "|| true" passes
    # whatever the test says, and neither line shows it.
    if (cont != "" || $0 ~ /\\$/) {
        if (cont == "") cont_line = FNR
        joined = $0
        if (joined ~ /\\$/) {
            sub(/\\$/, " ", joined)
            cont = cont joined
        } else {
            at = cont_line
            only_true = 1
            check(cont joined, 0)
            only_true = 0
            cont = ""
        }
    }
}
END {
    if (str != "") flag(str_file, str_line, str_text, "a quoted string opened here never closes, so the lint cannot tell what follows it from the string")
    if (bad) {
        printf "%d assertion(s) that can never fail\n", bad
        exit 1
    }
}
' "$@"
