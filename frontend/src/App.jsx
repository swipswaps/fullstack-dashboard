import React, { useState, useEffect } from 'react';
import './App.css';

// Use absolute URL in production, relative in development
const API_BASE = import.meta.env.PROD 
  ? 'http://localhost:3001/api'
  : '/api';

function App() {
  const [backendStatus, setBackendStatus] = useState('Checking...');
  const [data, setData] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Check backend health using absolute URL in production
    fetch(`${API_BASE}/health`)
      .then(res => res.json())
      .then(data => setBackendStatus(data.message || 'OK'))
      .catch(() => setBackendStatus('Backend not reachable'));

    // Fetch sample data
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
