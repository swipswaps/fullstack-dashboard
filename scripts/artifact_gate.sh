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

# ---------------------------------------------------------------------------
# JS LINTER RESOLUTION - the fix for a proven fail-open defect.
#
# On a machine where oxlint is not on PATH, "npx --no-install oxlint" exits 1
# with:  npm error npx canceled due to missing packages and no YES option
# That message contains neither "no-undef" nor any parse keyword, so the old
# branch logic fell through to PASS. Result: 24 artifacts reported PASS while
# the linter had never executed once. bats test 7 is what exposed it.
#
# This resolver finds a runner that can ACTUALLY execute, verified by
# --version, and searches repo-local node_modules/.bin (where lint_and_resolve
# installed oxlint) before giving up. If nothing runs, the caller reports
# SKIP - never PASS (Rule #37).
# ---------------------------------------------------------------------------
JS_LINTER=""
JS_LINT_CFG=""

# ---------------------------------------------------------------------------
# CONFIG RESOLUTION - fixes a false-positive class proven in a live run.
#
# The gate copies each artifact to a temp dir before linting. oxlint discovers
# .oxlintrc.json by walking up from the FILE, so a temp path finds nothing and
# falls back to defaults, where browser globals are undefined. A real run
# reported 'window', 'fetch', 'setInterval' and 'clearInterval' as undefined
# in seven App.jsx artifacts that are perfectly valid browser code.
#
# Reproduced, then verified: passing -c <project .oxlintrc.json> eliminates
# all four false positives AND still reports a genuinely undefined identifier.
# ---------------------------------------------------------------------------
resolve_js_config() {
    local root cand
    root=$(git rev-parse --show-toplevel 2>&1) || root="."
    for cand in "$root/.oxlintrc.json" "$root/frontend/.oxlintrc.json"; do
        if [ -f "$cand" ]; then
            JS_LINT_CFG="$cand"
            return 0
        fi
    done
    JS_LINT_CFG=""
    return 1
}

resolve_js_linter() {
    local root cand
    root=$(git rev-parse --show-toplevel 2>&1) || root="."
    if have oxlint && oxlint --version > /dev/null 2>&1; then
        JS_LINTER="oxlint"
        return 0
    fi
    for cand in \
        "$root/node_modules/.bin/oxlint" \
        "$root/frontend/node_modules/.bin/oxlint" \
        "$root/backend/node_modules/.bin/oxlint"
    do
        if [ -x "$cand" ] && "$cand" --version > /dev/null 2>&1; then
            JS_LINTER="$cand"
            return 0
        fi
    done
    if have npx && npx --no-install oxlint --version > /dev/null 2>&1; then
        JS_LINTER="npx --no-install oxlint"
        return 0
    fi
    JS_LINTER=""
    return 1
}

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
            if [ -n "$JS_LINTER" ]; then
                # shellcheck disable=SC2086  # JS_LINTER may be "npx --no-install oxlint"
                if [ -n "$JS_LINT_CFG" ]; then
                    $JS_LINTER -c "$JS_LINT_CFG" --deny no-undef "$as_mjs" > "$WORK/ox.out" 2>&1
                else
                    $JS_LINTER --deny no-undef "$as_mjs" > "$WORK/ox.out" 2>&1
                fi
                local ox_rc=$?
                if [ "$(grep -c 'no-undef' "$WORK/ox.out" || true)" -ge 1 ]; then
                    fail "$target" "oxlint no-undef: undefined identifier"
                    grep -A2 'no-undef' "$WORK/ox.out" | head -12
                elif [ "$(grep -ciE 'parse|unexpected|expected' "$WORK/ox.out" || true)" -ge 1 ]; then
                    # FAIL CLOSED: a parse error means no-undef was never
                    # evaluated, so "no finding" proves nothing.
                    fail "$target" "oxlint could not parse the artifact"
                    head -12 "$WORK/ox.out"
                elif [ "$ox_rc" -ne 0 ] && [ ! -s "$WORK/ox.out" ]; then
                    fail "$target" "linter exited $ox_rc with no output - cannot trust a silent verdict"
                elif [ "$(grep -ciE 'npm error|command not found|could not determine' "$WORK/ox.out" || true)" -ge 1 ]; then
                    # FAIL CLOSED on runner failure. This is the exact case
                    # that produced 24 false PASSes.
                    fail "$target" "linter runner failed to execute - verdict is meaningless"
                    head -6 "$WORK/ox.out"
                else
                    pass "$target" "oxlint no-undef ($JS_LINTER)"
                fi
            else
                skip "$target" "oxlint (no runnable linter found on PATH, in npx, or in any node_modules/.bin)"
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

if resolve_js_linter; then
    printf 'js linter: %s\n' "$JS_LINTER"
else
    printf 'js linter: NONE RUNNABLE - JS artifacts will report SKIP, never PASS\n'
fi
if resolve_js_config; then
    printf 'js linter config: %s\n' "$JS_LINT_CFG"
else
    printf 'js linter config: NONE FOUND - browser globals may report as undefined\n'
fi

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
