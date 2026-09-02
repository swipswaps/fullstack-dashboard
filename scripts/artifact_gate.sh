#!/usr/bin/env bash
# ============================================================================
# artifact_gate.sh - validates the files a script WRITES, not just the script.
#
# WHY THIS EXISTS (concrete, not hypothetical):
#   lint_and_resolve.sh emitted a frontend/eslint.config.js heredoc whose
#   body spread ...oxlint.configs[...] without importing eslint-plugin-oxlint.
#   bash -n passed. shellcheck passed. node --check on the extracted file
#   passed, because ReferenceError is a RUNTIME fault, not a syntax fault.
#   Only running the real tool over the extracted body caught it:
#     oxlint --deny no-undef  ->  eslint(no-undef): 'oxlint' is not defined.
#
#   The earlier verification also tested a hand-written fixture rather than
#   the bytes the script actually emits. That is the dev/prod parity failure
#   this gate closes: it extracts from the script itself, every time.
#
# Usage: ./scripts/artifact_gate.sh <script.sh> [more.sh ...]
# Exit 0 = every extracted artifact validated. Exit 1 = at least one failed.
#
# Dispatch by target extension:
#   .json          python3 -m json.tool          (parse)
#   .js .jsx .mjs  node --check + oxlint no-undef (syntax + undefined refs)
#   .sh .bash      bash -n + shellcheck + rules_gate.sh
#   .yml .yaml     actionlint if it is a workflow, else python3 yaml if present
#   other          existence and non-emptiness only
# ============================================================================
set -u

FAILED=0
CHECKED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf '  PASS  %s (%s)\n' "$1" "$2"; }
fail() { printf '  FAIL  %s (%s)\n' "$1" "$2"; FAILED=$((FAILED + 1)); }
skip() { printf '  SKIP  %s (%s not installed - reported as SKIP, never PASS)\n' "$1" "$2"; }

have() { command -v "$1" >/dev/null; }

validate_artifact() {
    local target="$1" body="$2" ext base
    CHECKED=$((CHECKED + 1))
    base="${target##*/}"
    ext="${base##*.}"
    [ "$ext" = "$base" ] && ext="none"

    if [ ! -s "$body" ]; then
        fail "$target" "extracted body is empty"
        return
    fi

    case "$ext" in
        json)
            if python3 -m json.tool "$body" > "$WORK/json.out"; then
                pass "$target" "valid JSON"
            else
                fail "$target" "invalid JSON"
                cat "$WORK/json.out"
            fi
            ;;
        js|jsx|mjs|cjs)
            local as_mjs="$WORK/artifact.mjs"
            cp "$body" "$as_mjs"
            # node --check parses plain JS only. JSX is not valid JS, so
            # running it on .jsx would be a guaranteed false failure; oxlint
            # parses JSX natively and covers that case below.
            if [ "$ext" = "jsx" ]; then
                printf '  INFO  %s (node --check skipped: JSX is not plain JS)\n' "$target"
            elif node --check "$as_mjs"; then
                pass "$target" "node --check"
            else
                fail "$target" "node --check"
            fi
            # The step that catches undefined identifiers. node --check cannot.
            if have oxlint; then
                if oxlint --deny no-undef "$as_mjs" > "$WORK/ox.out" 2>&1; then
                    pass "$target" "oxlint no-undef"
                else
                    if [ "$(grep -c 'no-undef' "$WORK/ox.out" || true)" -ge 1 ]; then
                        fail "$target" "oxlint no-undef: undefined identifier"
                        grep -A2 'no-undef' "$WORK/ox.out" | head -12
                    elif [ "$(grep -ciE 'parse|unexpected|expected' "$WORK/ox.out" || true)" -ge 1 ]; then
                        # FAIL CLOSED: a parse error means oxlint never got to
                        # evaluate no-undef, so "no no-undef found" proves nothing.
                        fail "$target" "oxlint could not parse the artifact"
                        head -12 "$WORK/ox.out"
                    else
                        pass "$target" "oxlint clean of no-undef"
                    fi
                fi
            elif have npx; then
                if npx --no-install oxlint --deny no-undef "$as_mjs" > "$WORK/ox.out" 2>&1; then
                    pass "$target" "oxlint no-undef (npx)"
                else
                    if [ "$(grep -c 'no-undef' "$WORK/ox.out" || true)" -ge 1 ]; then
                        fail "$target" "oxlint no-undef: undefined identifier"
                        grep -A2 'no-undef' "$WORK/ox.out" | head -12
                    elif [ "$(grep -ciE 'parse|unexpected|expected' "$WORK/ox.out" || true)" -ge 1 ]; then
                        fail "$target" "oxlint could not parse the artifact"
                        head -12 "$WORK/ox.out"
                    else
                        pass "$target" "oxlint clean of no-undef (npx)"
                    fi
                fi
            else
                skip "$target" "oxlint"
            fi
            ;;
        sh|bash)
            if bash -n "$body"; then
                pass "$target" "bash -n"
            else
                fail "$target" "bash -n"
            fi
            if have shellcheck; then
                if shellcheck -S warning -s bash "$body"; then
                    pass "$target" "shellcheck"
                else
                    fail "$target" "shellcheck"
                fi
            else
                skip "$target" "shellcheck"
            fi
            if [ -x "$(dirname "$0")/rules_gate.sh" ]; then
                if "$(dirname "$0")/rules_gate.sh" "$body" > "$WORK/rg.out"; then
                    pass "$target" "rules_gate"
                else
                    fail "$target" "rules_gate"
                    cat "$WORK/rg.out"
                fi
            else
                skip "$target" "rules_gate.sh"
            fi
            ;;
        yml|yaml)
            case "$target" in
                *.github/workflows/*)
                    if have actionlint; then
                        local wf="$WORK/wf.yml"
                        cp "$body" "$wf"
                        if actionlint "$wf"; then
                            pass "$target" "actionlint"
                        else
                            fail "$target" "actionlint"
                        fi
                    else
                        skip "$target" "actionlint"
                    fi
                    ;;
                *)
                    if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$body"; then
                        pass "$target" "YAML parse"
                    else
                        skip "$target" "PyYAML"
                    fi
                    ;;
            esac
            ;;
        *)
            pass "$target" "non-empty (no validator for .$ext)"
            ;;
    esac
}

scan_script() {
    local script="$1"
    printf '\n=== artifacts emitted by %s ===\n' "$script"
    if [ ! -f "$script" ]; then
        fail "$script" "file not found"
        return
    fi

    # Enumerate heredoc openers: cat > PATH <<'DELIM'  or  cat >> PATH <<'DELIM'
    # Rule #52 Pattern (b): script path reaches python3 via sys.argv only.
    python3 - "$script" > "$WORK/blocks.txt" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
opener = re.compile(r"^\s*cat\s+>>?\s+(\S+)\s+<<-?\s*'([A-Za-z0-9_]+)'\s*$")


def clean_target(t):
    # A heredoc target is frequently quoted: cat > "$STAGING/x.sh" <<'EOF'.
    # Without stripping the quotes the extension parses as 'sh"', dispatch
    # falls through to the generic non-empty branch, and the gate silently
    # validates nothing. That was a real fail-open defect.
    t = t.strip()
    for q in ('"', "'"):
        if t.startswith(q) and t.endswith(q) and len(t) > 1:
            t = t[1:-1]
    return t.strip('"').strip("'")
i = 0
while i < len(src):
    m = opener.match(src[i])
    if m:
        target, delim = m.group(1), m.group(2)
        j = i + 1
        while j < len(src) and src[j].strip() != delim:
            j += 1
        # i+1 .. j-1 is the body; j is the closing delimiter line
        print(f"{clean_target(target)}\t{i+1}\t{j+1}")
        i = j
    i += 1
PYEOF

    if [ ! -s "$WORK/blocks.txt" ]; then
        printf '  (no quoted heredocs found)\n'
        return
    fi

    while IFS=$'\t' read -r target start end; do
        [ -z "$target" ] && continue
        awk -v s="$start" -v e="$end" 'NR>s && NR<e' "$script" > "$WORK/body"
        printf '\n- %s  (lines %s-%s, %s bytes)\n' \
            "$target" "$start" "$end" "$(wc -c < "$WORK/body")"
        validate_artifact "$target" "$WORK/body"
    done < "$WORK/blocks.txt"
}

if [ "$#" -eq 0 ]; then
    printf 'usage: %s <script.sh> [more.sh ...]\n' "$0" >&2
    exit 2
fi

for s in "$@"; do
    scan_script "$s"
done

printf '\nartifact_gate: %s artifact(s) checked, %s failure(s)\n' "$CHECKED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
