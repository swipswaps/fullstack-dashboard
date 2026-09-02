#!/usr/bin/env bats
# Runtime tests for the gates. Run with: bats tests/gates.bats
# Each gate is tested in BOTH directions: it must fire on a violation AND
# stay silent on compliant code. A gate that only ever passes is worthless.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

@test "rules_gate flags a banned stream-editor invocation" {
    printf '#!/usr/bin/env bash\nsed -i s/a/b/ f.txt\n' > "$TMP/bad.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/bad.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RULE-7"* ]]
}

@test "rules_gate does NOT flag the words passed, guessed, based" {
    printf '#!/usr/bin/env bash\nX="passed and guessed and based"\nprintf %%s "$X"\n' > "$TMP/ok.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/ok.sh"
    [ "$status" -eq 0 ]
}

@test "rules_gate does NOT flag a rule merely named in a comment" {
    printf '#!/usr/bin/env bash\n# banned here: the stream editor, errexit, quiet grep\nset -u\n' > "$TMP/cmt.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/cmt.sh"
    [ "$status" -eq 0 ]
}

@test "rules_gate flags blanket errexit" {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$TMP/e.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/e.sh"
    [ "$status" -eq 1 ]
}

@test "rules_gate does NOT flag while-read file iteration" {
    printf '#!/usr/bin/env bash\nwhile IFS= read -r l; do printf %%s "$l"; done < f.txt\n' > "$TMP/w.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/w.sh"
    [ "$status" -eq 0 ]
}

@test "rules_gate DOES flag an interactive prompt read" {
    printf '#!/usr/bin/env bash\nread -r -p "press enter" X\n' > "$TMP/p.sh"
    run "$REPO_ROOT/scripts/rules_gate.sh" "$TMP/p.sh"
    [ "$status" -eq 1 ]
}

@test "artifact_gate flags a heredoc JS artifact with an undefined identifier" {
    {
        printf '#!/usr/bin/env bash\n'
        printf "cat > out.js <<'JS_EOF'\n"
        printf 'export default [...missingSymbol.configs.recommended];\n'
        printf 'JS_EOF\n'
    } > "$TMP/emit.sh"
    run "$REPO_ROOT/scripts/artifact_gate.sh" "$TMP/emit.sh"
    [ "$status" -eq 1 ]
}

@test "artifact_gate flags a malformed heredoc JSON artifact" {
    {
        printf '#!/usr/bin/env bash\n'
        printf "cat > out.json <<'J_EOF'\n"
        printf '{ "a": 1,, }\n'
        printf 'J_EOF\n'
    } > "$TMP/emitj.sh"
    run "$REPO_ROOT/scripts/artifact_gate.sh" "$TMP/emitj.sh"
    [ "$status" -eq 1 ]
}

@test "artifact_gate passes a well-formed heredoc JSON artifact" {
    {
        printf '#!/usr/bin/env bash\n'
        printf "cat > out.json <<'J_EOF'\n"
        printf '{ "a": 1 }\n'
        printf 'J_EOF\n'
    } > "$TMP/emitok.sh"
    run "$REPO_ROOT/scripts/artifact_gate.sh" "$TMP/emitok.sh"
    [ "$status" -eq 0 ]
}
