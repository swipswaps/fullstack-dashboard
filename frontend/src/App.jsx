import React, { useState, useEffect } from 'react';
import { Activity, Cpu, HardDrive, Network, Server, Zap, RefreshCw, AlertCircle } from 'lucide-react';
import { LineChart, Line, BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';
import './App.css';

const API_BASE = import.meta.env.PROD ? 'http://localhost:3001/api' : '/api';

function App() {
  const [backendStatus, setBackendStatus] = useState('Checking...');
  const [processes, setProcesses] = useState([]);
  const [forensic, setForensic] = useState(null);
  const [loading, setLoading] = useState(false);
  const [selectedPid, setSelectedPid] = useState(null);
  const [processDetail, setProcessDetail] = useState(null);
  const [cpuHistory, setCpuHistory] = useState([]);
  const [memoryHistory, setMemoryHistory] = useState([]);
  const [autoRefresh, setAutoRefresh] = useState(true);

  useEffect(() => {
    fetch(`${API_BASE}/health`)
      .then(r => r.json())
      .then(d => setBackendStatus(d.message || 'OK'))
      .catch(() => setBackendStatus('Backend not reachable'));
  }, []);

  useEffect(() => {
    if (!autoRefresh) return;
    const interval = setInterval(() => fetchProcesses(), 5000);
    return () => clearInterval(interval);
  }, [autoRefresh]);

  const fetchProcesses = () => {
    setLoading(true);
    fetch(`${API_BASE}/processes`)
      .then(r => r.json())
      .then(data => {
        const procs = data.processes || [];
        setProcesses(procs);
        const cpuAvg = procs.slice(0, 5).reduce((acc, p) => acc + parseFloat(p.cpu || 0), 0) / 5;
        const memAvg = procs.slice(0, 5).reduce((acc, p) => acc + parseFloat(p.mem || 0), 0) / 5;
        const timestamp = new Date().toISOString();
        setCpuHistory(prev => [...prev.slice(-19), { time: timestamp, value: cpuAvg }]);
        setMemoryHistory(prev => [...prev.slice(-19), { time: timestamp, value: memAvg }]);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  const runForensic = () => {
    setLoading(true);
    fetch(`${API_BASE}/forensic`)
      .then(r => r.json())
      .then(data => { setForensic(data); setLoading(false); })
      .catch(() => setLoading(false));
  };

  const fetchProcessDetail = (pid) => {
    setSelectedPid(pid);
    fetch(`${API_BASE}/process/${pid}`)
      .then(r => r.json())
      .then(data => setProcessDetail(data))
      .catch(() => setProcessDetail(null));
  };

  const formatUptime = (s) => {
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    return `${d}d ${h}h ${m}m`;
  };

  return (
    <div className="App">
      <aside className="sidebar">
        <div className="logo">🔬 FD</div>
        <nav>
          <a href="#" className="active"><Activity size={20} /> Dashboard</a>
          <a href="#" onClick={(e) => { e.preventDefault(); fetchProcesses(); }}><Server size={20} /> Processes</a>
          <a href="#" onClick={(e) => { e.preventDefault(); runForensic(); }}><AlertCircle size={20} /> Forensic</a>
        </nav>
      </aside>
      <main className="main">
        <header className="topbar">
          <h1>System Resource Forensic Dashboard</h1>
          <div className="status-badge">
            <span className={backendStatus === 'Backend not reachable' ? 'offline' : 'online'}>
              {backendStatus}
            </span>
            <button onClick={() => setAutoRefresh(!autoRefresh)}>
              <RefreshCw size={16} className={autoRefresh ? 'spin' : ''} />
            </button>
          </div>
        </header>

        <section className="grid">
          <div className="card">
            <div className="card-header"><Cpu size={20} /> CPU Load</div>
            <div className="card-value">{forensic?.loadavg || 'N/A'}</div>
            <div className="card-sub">1, 5, 15 min</div>
          </div>
          <div className="card">
            <div className="card-header"><HardDrive size={20} /> Memory</div>
            <div className="card-value">
              {forensic?.system ? `${Math.round(forensic.system.freemem / 1024 / 1024)} MB free` : 'N/A'}
            </div>
            <div className="card-sub">of {forensic?.system ? Math.round(forensic.system.totalmem / 1024 / 1024) : '?'} MB</div>
          </div>
          <div className="card">
            <div className="card-header"><Activity size={20} /> Uptime</div>
            <div className="card-value">{forensic?.system ? formatUptime(forensic.system.uptime) : 'N/A'}</div>
            <div className="card-sub">since last boot</div>
          </div>
          <div className="card">
            <div className="card-header"><Network size={20} /> Processes</div>
            <div className="card-value">{processes.length}</div>
            <div className="card-sub">running</div>
          </div>
        </section>

        <section className="charts">
          <div className="chart-card">
            <h3>CPU Usage (Top 5 Avg)</h3>
            <ResponsiveContainer width="100%" height={120}>
              <LineChart data={cpuHistory}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="time" tick={false} />
                <YAxis domain={[0, 100]} />
                <Tooltip />
                <Line type="monotone" dataKey="value" stroke="#00d4ff" strokeWidth={2} dot={false} />
              </LineChart>
            </ResponsiveContainer>
          </div>
          <div className="chart-card">
            <h3>Memory Usage (Top 5 Avg)</h3>
            <ResponsiveContainer width="100%" height={120}>
              <BarChart data={memoryHistory}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="time" tick={false} />
                <YAxis domain={[0, 100]} />
                <Tooltip />
                <Bar dataKey="value" fill="#ffcc00" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </section>

        <section className="table-section">
          <h3>Process List (by CPU)</h3>
          {loading && <div className="spinner">Loading...</div>}
          <div className="table-wrapper">
            <table>
              <thead><tr><th>PID</th><th>PPID</th><th>User</th><th>CPU%</th><th>MEM%</th><th>Time</th><th>Command</th><th>Detail</th></tr></thead>
              <tbody>
                {processes.slice(0, 30).map(p => (
                  <tr key={p.pid}>
                    <td>{p.pid}</td><td>{p.ppid}</td><td>{p.user}</td>
                    <td>{p.cpu}</td><td>{p.mem}</td><td>{p.etime}</td>
                    <td className="cmd">{p.cmd.slice(0, 40)}</td>
                    <td><button onClick={() => fetchProcessDetail(p.pid)}>🔍</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {forensic && (
          <section className="forensic-section">
            <h3>Forensic Report</h3>
            <div className="forensic-grid">
              <div className="forensic-card">
                <h4>High CPU (&gt;80%)</h4>
                <pre>{forensic.high_cpu_processes || 'None'}</pre>
              </div>
              <div className="forensic-card">
                <h4>Asciinema</h4>
                <pre>{forensic.asciinema_processes || 'None'}</pre>
              </div>
            </div>
          </section>
        )}

        {processDetail && (
          <div className="modal-overlay" onClick={() => setProcessDetail(null)}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
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
          </div>
        )}
      </main>
    </div>
  );
}

export default App;
