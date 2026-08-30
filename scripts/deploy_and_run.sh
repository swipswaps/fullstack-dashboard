#!/usr/bin/env bash
#
# deploy_and_run.sh – permanent script for the full‑stack dashboard.
# Run from the project root: ./scripts/deploy_and_run.sh

set -u

# 1. Ensure we are in the project root
if [[ ! -f "package.json" ]]; then
    echo "ERROR: Please run this script from the project root (where package.json is)."
    exit 1
fi
PROJECT_DIR="$(pwd)"
echo "--- Project root: $PROJECT_DIR ---"

# 2. Ensure Node and npm are available
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

# 3. Install dependencies if missing
echo "--- Ensuring dependencies are installed ---"
if [[ ! -d "node_modules" ]] || [[ ! -d "frontend/node_modules" ]] || [[ ! -d "backend/node_modules" ]]; then
    npm run install:all
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Dependency installation failed."
        exit 1
    fi
else
    echo "Dependencies already installed."
fi

# 4. Ensure frontend uses absolute URL for production (idempotent)
echo "--- Ensuring frontend uses absolute URL for backend ---"
if ! grep -q "http://localhost:3001/api" frontend/src/App.jsx; then
    echo "Updating App.jsx to use absolute URL in production..."
    cat > frontend/src/App.jsx <<'APP_JSX'
import React, { useState, useEffect } from 'react';
import './App.css';

const API_BASE = import.meta.env.PROD 
  ? 'http://localhost:3001/api'
  : '/api';

function App() {
  const [backendStatus, setBackendStatus] = useState('Checking...');
  const [data, setData] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(`${API_BASE}/health`)
      .then(res => res.json())
      .then(data => setBackendStatus(data.message || 'OK'))
      .catch(() => setBackendStatus('Backend not reachable'));

    fetch(`${API_BASE}/data`)
      .then(res => res.json())
      .then(data => {
        setData(data.items || []);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, []);

  return (
    <div className="App">
      <header className="App-header">
        <h1>Full‑stack Dashboard</h1>
        <p>Frontend on GitHub Pages • Backend runs locally</p>
        <div className="status-card">
          <h3>Backend Status</h3>
          <p className={backendStatus === 'Backend not reachable' ? 'offline' : 'online'}>
            {backendStatus}
          </p>
          <p className="hint">
            {backendStatus === 'Backend not reachable'
              ? 'Start the backend with: npm run dev:backend (in project root)'
              : 'Backend is reachable.'}
          </p>
        </div>
        <div className="data-card">
          <h3>Sample Data</h3>
          {loading ? <p>Loading...</p> : (
            <ul>
              {data.map((item, idx) => <li key={idx}>{item}</li>)}
            </ul>
          )}
        </div>
      </header>
    </div>
  );
}

export default App;
APP_JSX
    echo "App.jsx updated."
else
    echo "App.jsx already uses absolute URL."
fi

# 5. Get GitHub Pages URL and current branch
GITHUB_USER=""
REMOTE_URL=$(git config --get remote.origin.url)
if echo "$REMOTE_URL" | grep -q "github.com"; then
    GITHUB_USER=$(echo "$REMOTE_URL" | sed -E 's/.*github\.com[:/]([^/]+)\/.*/\1/' 2>&1 || true)
fi
if [[ -z "$GITHUB_USER" ]]; then
    GITHUB_USER="swipswaps"
fi
PAGES_URL="https://${GITHUB_USER}.github.io/fullstack-dashboard"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
echo "Current branch: $CURRENT_BRANCH"

# 6. Start the dev server in the background
echo "--- Starting the dev server (frontend on 5173, backend on 3001) ---"
pkill -f "npm run dev" 2>/dev/null || true
pkill -f "vite" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true

npm run dev &
DEV_PID=$!

# 7. Wait for backend to be ready (poll /api/health)
echo "Waiting for backend (http://localhost:3001/api/health)..."
while true; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/api/health 2>&1 || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "Backend ready (HTTP 200)."
        break
    fi
    sleep 1
done

# 8. Wait for frontend to be ready (poll the main page)
echo "Waiting for frontend (http://localhost:5173)..."
while true; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5173 2>&1 || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "Frontend ready (HTTP 200)."
        break
    fi
    sleep 1
done

# 9. Open local frontend
LOCAL_URL="http://localhost:5173/"
echo "--- Opening local frontend at $LOCAL_URL ---"
if command -v xdg-open >/dev/null 2>&1; then xdg-open "$LOCAL_URL"
elif command -v open >/dev/null 2>&1; then open "$LOCAL_URL"
elif command -v firefox >/dev/null 2>&1; then firefox "$LOCAL_URL"
else echo "Please open $LOCAL_URL manually"
fi

# 10. Open GitHub Pages
echo "--- Opening GitHub Pages at $PAGES_URL ---"
sleep 2
if command -v xdg-open >/dev/null 2>&1; then xdg-open "$PAGES_URL"
elif command -v open >/dev/null 2>&1; then open "$PAGES_URL"
elif command -v firefox >/dev/null 2>&1; then firefox "$PAGES_URL"
else echo "Please open $PAGES_URL manually"
fi

# 11. Instructions
cat <<'FINAL_INSTRUCTIONS'

===============================================================================
✅ Local development server is running!

Local frontend: $LOCAL_URL
Local backend:  http://localhost:3001
GitHub Pages:   $PAGES_URL

The frontend will now use an absolute URL (http://localhost:3001/api) in production,
so GitHub Pages can detect your local backend when it's running.

To stop the dev server, press Ctrl+C in this terminal.

To redeploy the frontend to Pages (after this fix), run:
  git add .
  git commit -m "Fix: use absolute URL for backend"
  git push origin $CURRENT_BRANCH

===============================================================================
FINAL_INSTRUCTIONS

echo "Dev server is running. Press Ctrl+C to stop."
wait $DEV_PID
