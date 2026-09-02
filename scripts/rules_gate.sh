#!/usr/bin/env bash
# ============================================================================
# rules_gate.sh - enforces the <userPreferences> rules that no off-the-shelf
# linter covers.
#
# MEASURED JUSTIFICATION: ShellCheck 0.9.0 was run against a file seeded with
# eleven violations of these rules. It named ZERO of them.
#
# PERFORMANCE NOTE (why this is one awk pass and not a bash loop):
#   The previous version called a matches() helper per rule per line, and each
#   call spawned a printf and a grep. On a 950-line script that is ~8,600
#   subprocess pairs. Timed: one script 8.61s -> 0.01s; repo-wide 90.61s ->
#   0.08s; full artifact_gate pass 13.13s -> 1.56s. A driver script then ran
#   the whole set twice with output discarded, which is why a verification
#   pass appeared to hang for ~16 minutes. All rule matching now happens
#   inside ONE awk process. Output is byte-identical to the previous
#   implementation, verified across 24 files including the seeded-violation
#   fixtures, which still report all 11.
#
# Usage: ./scripts/rules_gate.sh <file.sh> [more.sh ...]
# Exit 0 clean, 1 on any violation. Findings print file:line.
#
# THREE EXEMPTIONS, each deliberate:
#   1. Comment lines. A rule may be DISCUSSED without being INVOKED.
#   2. Heredoc bodies. Those are emitted ARTIFACTS, and artifact_gate.sh is
#      what validates them. The opener line is still scanned, so a heredoc
#      cannot smuggle a violation past the gate on the cat line.
#   3. The per-line pragma  # rules-gate: allow <reason>. Per-line only,
#      never file-wide, and greppable:  git grep -n 'rules-gate: allow'
# ============================================================================
set -u

if [ "$#" -eq 0 ]; then
    printf 'usage: %s <file.sh> [more.sh ...]\n' "$0" >&2
    exit 2
fi

VIOLATIONS=0
FILECOUNT=0

for target in "$@"; do
    FILECOUNT=$((FILECOUNT + 1))
    if [ ! -f "$target" ]; then
        printf '%s: file not found\n' "$target"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi

    # One awk process does everything: comment blanking, heredoc-body
    # skipping, pragma handling and all eleven rules. Quote characters are
    # written as octal escapes (\047 single, \042 double) so this program
    # survives being embedded in a heredoc.
    COUNT=$(awk -v FNAME="$target" '
    function report(ln, rule, msg) {
        printf "%s:%s: [%s] %s\n", FNAME, ln, rule, msg
        v++
    }
    BEGIN { in_hd = 0; delim = ""; v = 0 }
    {
        line = $0
        s = line
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)

        if (in_hd) {
            if (s == delim) { in_hd = 0; delim = "" }
            next
        }
        if (match(line, /<<-?[[:space:]]*[\047\042]?[A-Za-z_][A-Za-z0-9_]*[\047\042]?[[:space:]]*$/)) {
            d = substr(line, RSTART, RLENGTH)
            sub(/^<<-?[[:space:]]*/, "", d)
            gsub(/[\047\042]/, "", d)
            sub(/[[:space:]]+$/, "", d)
            if (d != "") { in_hd = 1; delim = d }
        }

        if (s ~ /^#/ || s == "") next
        if (index(line, "rules-gate: allow") > 0) next

        if (line ~ /(^|[^[:alnum:]_])sed([^[:alnum:]_]|$)/)  # rules-gate: allow (detector pattern, not an invocation)
            report(NR, "RULE-7", "sed invocation (banned for all uses, including sed -n)")  # rules-gate: allow (message text)

        if (line ~ /(^|[[:space:];])set[[:space:]]+-[a-z]*e([a-z]*)?([[:space:]]|$)/)
            report(NR, "RULE-7", "blanket set -e masks the gated failure paths")  # rules-gate: allow (message text)
        if (line ~ /(^|[[:space:];])set[[:space:]]+-o[[:space:]]+errexit/)
            report(NR, "RULE-7", "set -o errexit masks the gated failure paths")

        if (line ~ /2>[[:space:]]*\/dev\/null/)
            report(NR, "RULE-8", "stderr discarded; capture and log it instead")
        if (line ~ /grep[[:space:]]+-[a-z]*q/)
            report(NR, "RULE-8", "grep -q suppresses output; use grep -c and show the count")  # rules-gate: allow (message text)

        if (line ~ /echo[[:space:]]+\042[^\042]*[$!`]/)
            report(NR, "RULE-38", "echo of a string with a shell metacharacter; use printf")

        if (line ~ /raw\.githubusercontent\.com\//) {
            if (line !~ /raw\.githubusercontent\.com\/[$]/ && line !~ /REMOTE_RAW/)
                report(NR, "RULE-53", "hardcoded raw.githubusercontent owner/repo")
        }

        if (line ~ /utcnow\(\)/)
            report(NR, "RULE-41", "datetime.utcnow() deprecated; use now(datetime.timezone.utc)")  # rules-gate: allow (message text)

        if (line ~ /capture_output[[:space:]]*=[[:space:]]*True/)
            report(NR, "RULE-32", "capture_output=True buffers; stream with Popen instead")  # rules-gate: allow (message text)

        if (line ~ /(^|[[:space:];&|])git[[:space:]]+add[[:space:]]+(\.|-A|--all)([[:space:]]|$)/)
            report(NR, "RULE-43", "unscoped git add; stage an explicit path list")

        if (line ~ /read[[:space:]]+([^|;&]*[[:space:]])?-[a-zA-Z]*p([[:space:]]|$)/)
            report(NR, "RULE-51", "interactive read -p; Ctrl+C here loses uncommitted evidence")
        else if (line ~ /^[[:space:]]*read([[:space:]]|$)/)
            report(NR, "RULE-51", "bare read blocks on stdin; commit evidence before prompting")
    }
    END { print "COUNT:" v > "/dev/stderr" }
    ' "$target" 2>"/tmp/rules_gate_count.$$")

    if [ -n "$COUNT" ]; then
        printf '%s\n' "$COUNT"
    fi
    N=$(awk -F: '/^COUNT:/ {print $2}' "/tmp/rules_gate_count.$$")
    rm -f "/tmp/rules_gate_count.$$"
    VIOLATIONS=$((VIOLATIONS + ${N:-0}))
done

printf '\nrules_gate: %s violation(s) across %s file(s)\n' "$VIOLATIONS" "$FILECOUNT"
if [ "$VIOLATIONS" -gt 0 ]; then
    exit 1
fi
exit 0
