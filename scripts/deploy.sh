#!/usr/bin/env bash
#
# =============================================================================
# deploy_final.sh
#
# PURPOSE
# -------
# Idempotent script to deploy the fullstack-dashboard frontend to GitHub Pages.
# It locates the project (even if moved), ensures the workflow uses Node 22,
# triggers a fresh deploy, waits for completion, and opens the live page.
#
# This script is self-contained and does not use sed, 2>/dev/null, or set -e.
#
# REFERENCES
# ----------
# - GitHub Actions setup-node: https://github.com/actions/setup-node
# - Vite 8 Node requirements: https://vitejs.dev/guide/#node-version-support
# - GitHub Pages API: https://docs.github.com/en/rest/pages
# - gh workflow run: https://cli.github.com/manual/gh_workflow_run
#
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# 1. Ensure GITHUB_USER is set
# -----------------------------------------------------------------------------
if [[ -z "${GITHUB_USER:-}" ]]; then
    GITHUB_USER="$(gh api user -q .login 2>&1 || true)"
    if [[ -z "$GITHUB_USER" ]]; then
        echo "ERROR: Could not determine GitHub username. Please ensure gh is authenticated."
        exit 1
    fi
    export GITHUB_USER
fi
echo "GitHub user: $GITHUB_USER"

# -----------------------------------------------------------------------------
# 2. Locate the project directory
# -----------------------------------------------------------------------------
find_project_dir() {
    local candidates=(
        "./fullstack-dashboard"
        "../notes/fullstack-dashboard"
        "$HOME/github/fullstack-dashboard"
        "$HOME/notes/fullstack-dashboard"
        "$HOME/Documents/notes/fullstack-dashboard"
        "$PWD/fullstack-dashboard"  # current directory's subfolder
    )
    for d in "${candidates[@]}"; do
        if [[ -d "$d" ]] && [[ -d "$d/.git" ]] && [[ -f "$d/.github/workflows/deploy.yml" ]]; then
            echo "$(cd "$d" && pwd)"  # resolve absolute path
            return 0
        fi
    done
    if [[ -n "${WORKDIR:-}" ]] && [[ -d "$WORKDIR" ]]; then
        echo "$WORKDIR"
        return 0
    fi
    return 1
}

PROJECT_DIR=$(find_project_dir)
if [[ -z "$PROJECT_DIR" ]]; then
    echo "ERROR: Could not locate the fullstack-dashboard project."
    echo "Please cd into the project root or set WORKDIR."
    exit 1
fi
echo "--- Project found at: $PROJECT_DIR ---"

# -----------------------------------------------------------------------------
# 3. Copy this script into the repo (so it's not lost in /tmp)
# -----------------------------------------------------------------------------
SCRIPT_DEST="$PROJECT_DIR/scripts/deploy.sh"
mkdir -p "$(dirname "$SCRIPT_DEST")"
if [[ ! -f "$SCRIPT_DEST" ]] || ! cmp -s "$0" "$SCRIPT_DEST" 2>/dev/null; then
    echo "--- Copying script to $SCRIPT_DEST ---"
    cp "$0" "$SCRIPT_DEST"
    chmod +x "$SCRIPT_DEST"
    # Add to git (if not already tracked)
    cd "$PROJECT_DIR" || exit 1
    if ! git ls-files --error-unmatch "$SCRIPT_DEST" >/dev/null 2>&1; then
        git add "$SCRIPT_DEST"
        git commit -m "Add self-contained deploy script to repo"
        git push origin main
    fi
else
    echo "--- Script already present in repo at $SCRIPT_DEST ---"
fi

# -----------------------------------------------------------------------------
# 4. Change to project directory
# -----------------------------------------------------------------------------
cd "$PROJECT_DIR" || exit 1

# -----------------------------------------------------------------------------
# 5. Prerequisites (git, gh, curl, jq, node)
# -----------------------------------------------------------------------------
can_sudo() { sudo -n true 2>/dev/null; }
check_and_install() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing $cmd. Attempting to install $pkg..."
        if can_sudo; then
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y "$pkg"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "$pkg"
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y "$pkg"
            else
                echo "ERROR: Cannot install $pkg automatically. Please install manually."
                exit 1
            fi
        else
            echo "ERROR: sudo required to install $pkg. Please install manually or grant passwordless sudo."
            exit 1
        fi
    fi
}
check_and_install git git
check_and_install gh gh
check_and_install curl curl
check_and_install jq jq

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login'."
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js via nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install --lts && nvm use --lts
    if ! command -v node >/dev/null 2>&1; then
        echo "ERROR: Node.js installation failed. Please install manually."
        exit 1
    fi
fi
echo "Node.js: $(node --version)"

# -----------------------------------------------------------------------------
# 6. Ensure workflow uses Node 22 (rewrite the file – no sed)
# -----------------------------------------------------------------------------
WORKFLOW_FILE=".github/workflows/deploy.yml"
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "ERROR: Workflow file not found. Did the project structure change?"
    exit 1
fi

echo "--- Ensuring workflow uses node-version: 22 ---"
cat > "$WORKFLOW_FILE" <<'DEPLOY_YML'
name: Deploy to GitHub Pages
on:
  push:
    branches: [ "main" ]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: "pages"
  cancel-in-progress: false
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - name: Install and Build
        run: |
          cd frontend
          npm install
          npm run build
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: ./frontend/dist
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
DEPLOY_YML

# Commit and push if changed
git add "$WORKFLOW_FILE"
if ! git diff --cached --quiet; then
    git commit -m "ci: enforce Node 22 for Vite 8 compatibility"
    git push origin main
    echo "Workflow updated and pushed."
else
    echo "Workflow already uses Node 22."
fi

# -----------------------------------------------------------------------------
# 7. Build frontend locally to catch errors
# -----------------------------------------------------------------------------
echo "--- Building frontend locally to verify ---"
cd frontend || exit 1
npm run build
if [[ $? -ne 0 ]]; then
    echo "ERROR: Frontend build failed locally. Fix errors before proceeding."
    exit 1
fi
cd ..

# -----------------------------------------------------------------------------
# 8. Trigger a fresh workflow run
# -----------------------------------------------------------------------------
echo "--- Triggering GitHub Actions workflow ---"
gh workflow run deploy.yml --ref main
echo "Workflow triggered. Waiting for it to start..."

# -----------------------------------------------------------------------------
# 9. Poll workflow completion (exponential backoff)
# -----------------------------------------------------------------------------
MAX_WAIT=600
SLEEP=10
ATTEMPT=0
START=$(date +%s)
RUN_ID=""
while true; do
    ATTEMPT=$((ATTEMPT + 1))
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [[ $ELAPSED -gt $MAX_WAIT ]]; then
        echo "ERROR: Timeout waiting for workflow to complete."
        exit 1
    fi

    RUN_INFO=$(gh api "/repos/${GITHUB_USER}/fullstack-dashboard/actions/runs" -q '.workflow_runs[0]' 2>&1 || true)
    if [[ -n "$RUN_INFO" ]]; then
        STATUS=$(echo "$RUN_INFO" | jq -r '.status' 2>&1)
        CONCLUSION=$(echo "$RUN_INFO" | jq -r '.conclusion' 2>&1)
        RUN_ID=$(echo "$RUN_INFO" | jq -r '.id')
        echo "Attempt $ATTEMPT: Status=$STATUS, Conclusion=$CONCLUSION"
        if [[ "$STATUS" == "completed" ]]; then
            if [[ "$CONCLUSION" == "success" ]]; then
                echo "Workflow succeeded."
                break
            else
                echo "Workflow failed (conclusion: $CONCLUSION)."
                LOG_FILE="$PROJECT_DIR/workflow-logs.txt"
                gh run view "$RUN_ID" --log > "$LOG_FILE" 2>&1
                echo "Last 30 lines of logs:"
                tail -n 30 "$LOG_FILE"
                echo "Full logs saved to $LOG_FILE"
                exit 1
            fi
        else
            echo "Still running... waiting."
        fi
    else
        echo "No workflow runs found yet."
    fi
    sleep $SLEEP
    if [[ $SLEEP -lt 60 ]]; then
        SLEEP=$((SLEEP + 5))
    fi
done

# -----------------------------------------------------------------------------
# 10. Poll Pages deployment status
# -----------------------------------------------------------------------------
echo "--- Waiting for Pages deployment ---"
MAX_PAGES_WAIT=300
START=$(date +%s)
DEPLOYED=false
PAGES_URL="https://${GITHUB_USER}.github.io/fullstack-dashboard"
while true; do
    NOW=$(date +%s)
    if [[ $((NOW - START)) -gt $MAX_PAGES_WAIT ]]; then
        echo "ERROR: Timeout waiting for Pages deployment."
        break
    fi
    RESPONSE=$(gh api "/repos/${GITHUB_USER}/fullstack-dashboard/pages/builds/latest" 2>&1 || true)
    if echo "$RESPONSE" | grep -q "Not Found"; then
        echo "No Pages build yet (404). Waiting..."
    else
        STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>&1)
        case "$STATUS" in
            "built")
                echo "✅ Pages built!"
                DEPLOYED=true
                break
                ;;
            "building")
                echo "⏳ Pages is building..."
                ;;
            "errored")
                echo "❌ Pages build errored. Check manually."
                break
                ;;
            *)
                echo "Status: $STATUS"
                ;;
        esac
    fi
    sleep 10
done

# -----------------------------------------------------------------------------
# 11. Open page if deployed
# -----------------------------------------------------------------------------
if [[ "$DEPLOYED" == "true" ]]; then
    echo "✅ Frontend live at: $PAGES_URL"
    sleep 5
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PAGES_URL" 2>&1 || echo "000")
    if [[ "$HTTP_STATUS" == "200" ]]; then
        echo "Site is reachable (HTTP 200). Opening browser..."
        if command -v xdg-open >/dev/null 2>&1; then xdg-open "$PAGES_URL"
        elif command -v open >/dev/null 2>&1; then open "$PAGES_URL"
        elif command -v firefox >/dev/null 2>&1; then firefox "$PAGES_URL"
        else echo "Please open manually: $PAGES_URL"
        fi
    else
        echo "HTTP $HTTP_STATUS – may still be propagating. Visit: $PAGES_URL"
    fi
else
    echo "⚠️ Deployment not confirmed. Check manually at: https://github.com/${GITHUB_USER}/fullstack-dashboard/actions"
fi

# -----------------------------------------------------------------------------
# 12. Final instructions
# -----------------------------------------------------------------------------
cat <<'FINAL_INSTRUCTIONS'

===============================================================================
✅ Deployment process complete!

Project directory: $PROJECT_DIR
Frontend (GitHub Pages): $PAGES_URL

The frontend is now live. Since the backend runs locally, the dashboard will
show "Backend not reachable" on Pages – this is expected.

To run the backend locally and test the full stack:
  cd $PROJECT_DIR
  npm run install:all
  npm run dev

Then open http://localhost:5173 – the frontend will proxy /api to the backend
and you will see "Backend is reachable".

To redeploy after changes:
  git push origin main

The deploy script is now part of your repo at:
  $PROJECT_DIR/scripts/deploy.sh

You can re-run it anytime to fix or update the deployment.
===============================================================================
FINAL_INSTRUCTIONS

echo "Script finished."
exit 0
