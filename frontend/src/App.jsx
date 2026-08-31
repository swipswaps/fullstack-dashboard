import React, { useState, useEffect } from 'react';
import './App.css';

const API_BASE = import.meta.env.PROD ? 'http://localhost:3001/api' : '/api';

function App() {
  const [backendStatus, setBackendStatus] = useState('checking');
  const [processes, setProcesses] = useState([]);
  const [forensic, setForensic] = useState(null);
  const [loading, setLoading] = useState(false);
  const [selectedPid, setSelectedPid] = useState(null);
  const [processDetail, setProcessDetail] = useState(null);
  const [retryCount, setRetryCount] = useState(0);

  useEffect(() => {
    const checkBackend = () => {
      fetch(`${API_BASE}/health`)
        .then(r => {
          if (r.ok) {
            setBackendStatus('online');
            setRetryCount(0);
          } else {
            setBackendStatus('offline');
            setRetryCount(prev => prev + 1);
          }
        })
        .catch(() => {
          setBackendStatus('offline');
          setRetryCount(prev => prev + 1);
        });
    };
    checkBackend();
    const interval = setInterval(checkBackend, 5000);
    return () => clearInterval(interval);
  }, []);

  const fetchProcesses = () => {
    setLoading(true);
    fetch(`${API_BASE}/processes`)
      .then(r => r.json())
      .then(data => {
        setProcesses(data.processes || []);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  const runForensic = () => {
    setLoading(true);
    fetch(`${API_BASE}/forensic`)
      .then(r => r.json())
      .then(data => {
        setForensic(data);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  const fetchProcessDetail = (pid) => {
    setSelectedPid(pid);
    fetch(`${API_BASE}/process/${pid}`)
      .then(r => r.json())
      .then(data => setProcessDetail(data))
      .catch(() => setProcessDetail(null));
  };

  const projectPath = '/home/owner/Documents/6a9447c0-d534-83ea-b2c7-9ba48762a252/repo/fullstack-dashboard';
  const isGitHubPages = window.location.hostname.includes('github.io');

  return (
    <div className="App">
      <header className="App-header">
        <h1>🔬 System Resource Forensic Dashboard</h1>
        <p>Live system monitoring & forensic audit tools</p>

        <div className={`status-banner ${backendStatus}`}>
          {backendStatus === 'checking' && '⏳ Checking backend connection...'}
          {backendStatus === 'online' && (
            <>
              ✅ Backend is running – full functionality available
              <span className="status-dot online"></span>
            </>
          )}
          {backendStatus === 'offline' && (
            <>
              ⚠️ Backend not running – using limited/offline mode
              <span className="status-dot offline"></span>
              <div className="guidance">
                {isGitHubPages && (
                  <div className="github-pages-notice">
                    💡 You're viewing this on GitHub Pages
                    <br />
                    <small>For full functionality, run the backend locally.</small>
                  </div>
                )}
                <p>Start the backend with:</p>
                <code>cd {projectPath} && npm run dev:backend</code>
                {retryCount > 0 && (
                  <p className="retry-info">Connection attempts: {retryCount}</p>
                )}
                <p className="hint">Then refresh this page and click "Allow" if prompted.</p>
              </div>
            </>
          )}
        </div>

        <div className="controls">
          <button onClick={fetchProcesses} disabled={loading || backendStatus === 'offline'}>
            Refresh Processes
          </button>
          <button onClick={runForensic} disabled={loading || backendStatus === 'offline'}>
            Run Forensic Audit
          </button>
        </div>

        {backendStatus === 'offline' && (
          <div className="offline-notice">
            <p>💡 Some features are unavailable while the backend is offline.</p>
            <p>Start the backend using the command above to enable full functionality.</p>
          </div>
        )}

        {loading && <p>Loading...</p>}

        {forensic && (
          <div className="forensic-card">
            <h3>Forensic Report</h3>
            <pre>{forensic.top_processes}</pre>
            <h4>High CPU Processes (&gt;80%)</h4>
            <pre>{forensic.high_cpu_processes || 'None'}</pre>
            <h4>Asciinema Processes</h4>
            <pre>{forensic.asciinema_processes || 'None'}</pre>
            <h4>System Info</h4>
            <pre>Hostname: {forensic.system?.hostname}
Platform: {forensic.system?.platform}
Uptime: {forensic.system?.uptime}s
Memory: {Math.round(forensic.system?.freemem/1024/1024)}MB free / {Math.round(forensic.system?.totalmem/1024/1024)}MB total
CPUs: {forensic.system?.cpus}</pre>
          </div>
        )}

        {processes.length > 0 && (
          <div className="process-card">
            <h3>Process List (by CPU)</h3>
            <table>
              <thead><tr><th>PID</th><th>PPID</th><th>User</th><th>CPU%</th><th>MEM%</th><th>Time</th><th>Command</th><th>Detail</th></tr></thead>
              <tbody>
                {processes.slice(0, 30).map(p => (
                  <tr key={p.pid}>
                    <td>{p.pid}</td>
                    <td>{p.ppid}</td>
                    <td>{p.user}</td>
                    <td>{p.cpu}</td>
                    <td>{p.mem}</td>
                    <td>{p.etime}</td>
                    <td className="cmd">{p.cmd.slice(0, 40)}</td>
                    <td><button onClick={() => fetchProcessDetail(p.pid)}>🔍</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {processDetail && (
          <div className="detail-card">
            <h3>Process Detail: PID {selectedPid}</h3>
            <pre>{processDetail.status}</pre>
            <h4>I/O</h4>
            <pre>{processDetail.io}</pre>
            <h4>Command Line</h4>
            <pre>{processDetail.cmdline}</pre>
            <h4>Open FDs</h4>
            <pre>{processDetail.fds?.join('\n') || 'None'}</pre>
            <button onClick={() => setProcessDetail(null)}>Close</button>
          </div>
        )}

      </header>
    </div>
  );
}

export default App;
// CACHE_BUST: 1788215695
