Forensic Dashboard
==================

A local system forensics UI. The React frontend is deployed to GitHub Pages
as a static bundle. The Express backend runs on your own machine at
localhost:3001.

The deployed site is a UI shell. It polls http://localhost:3001/api/health
on load and shows an offline banner when no backend is running.

Deployed site: https://swipswaps.github.io/fullstack-dashboard/
Backend:       local only

Quick start
-----------

Two terminals.

Terminal 1 - backend:

    npm install
    npm run dev:backend

Terminal 2 - frontend:

    npm run dev:frontend

Then open http://localhost:5173.

The Vite dev server proxies /api requests to http://localhost:3001.

Running the deployed frontend against a local backend
-----------------------------------------------------

Open https://swipswaps.github.io/fullstack-dashboard/ in the same browser
where the backend is running. The deployed bundle calls
http://localhost:3001/api directly, so the two communicate over localhost.

Layout
------

    backend/        Express API server
    frontend/       React + Vite UI
    scripts/        Repository tooling
    tests/          Gate tests

Requirements
------------

- Node.js 22 or 24
- npm
