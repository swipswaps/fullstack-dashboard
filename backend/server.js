const express = require('express');
const cors = require('cors');
const { exec } = require('child_process');
const fs = require('fs');
const os = require('os');
const app = express();

// --- CORS + Local Network Access -----------------------------------------
// The published dashboard is served over HTTPS from *.github.io and calls
// http://localhost:3001. Chromium 142+ gates that behind Local Network Access:
// the browser sends a preflight and the loopback server must opt in, or the
// request never reaches these routes. Firefox and Safari do not implement LNA,
// so the page there will correctly report the backend as offline.
// Verified with real preflights: an allowed origin receives
// Access-Control-Allow-Private-Network: true; an unlisted origin receives no
// Access-Control-Allow-Origin at all.
const LNA_ALLOWED_ORIGIN = /^https:\/\/[a-z0-9-]+\.github\.io$/i;
app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && (LNA_ALLOWED_ORIGIN.test(origin) ||
                 origin.startsWith('http://localhost'))) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') {
    if (req.headers['access-control-request-private-network'] === 'true') {
      res.setHeader('Access-Control-Allow-Private-Network', 'true');
    }
    if (req.headers['access-control-request-local-network'] === 'true') {
      res.setHeader('Access-Control-Allow-Local-Network', 'true');
    }
    res.setHeader('Access-Control-Max-Age', '600');
    return res.status(204).end();
  }
  return next();
});
// --- end CORS + Local Network Access --------------------------------------
const port = process.env.PORT || 3001;
app.use(cors());
app.use(express.json());

function runCmd(cmd) {
  return new Promise((resolve, reject) => {
    exec(cmd, (err, stdout, stderr) => {
      if (err) reject(stderr || err.message);
      else resolve(stdout);
    });
  });
}

app.get('/api/processes', async (req, res) => {
  try {
    const out = await runCmd('ps -eo pid,ppid,user,pcpu,pmem,etime,args --sort=-pcpu');
    const lines = out.split('\n').filter(l => l.trim());
    const header = lines.shift();
    const processes = lines.map(line => {
      const parts = line.trim().split(/\s+/);
      return {
        pid: parts[0],
        ppid: parts[1],
        user: parts[2],
        cpu: parts[3],
        mem: parts[4],
        etime: parts[5],
        cmd: parts.slice(6).join(' ')
      };
    });
    res.json({ processes, header });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/process/:pid', async (req, res) => {
  const pid = req.params.pid;
  try {
    const status = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
    const io = fs.readFileSync(`/proc/${pid}/io`, 'utf8');
    const cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').replace(/\0/g, ' ');
    const fdDir = `/proc/${pid}/fd`;
    let fds = [];
    if (fs.existsSync(fdDir)) {
      fds = fs.readdirSync(fdDir).map(fd => {
        try { return fs.readlinkSync(`${fdDir}/${fd}`); } catch (e) { return null; }
      }).filter(l => l);
    }
    res.json({
      pid,
      status,
      io,
      cmdline,
      fds,
      cwd: fs.existsSync(`/proc/${pid}/cwd`) ? fs.readlinkSync(`/proc/${pid}/cwd`) : null,
      exe: fs.existsSync(`/proc/${pid}/exe`) ? fs.readlinkSync(`/proc/${pid}/exe`) : null,
    });
  } catch (err) {
    res.status(404).json({ error: `Process ${pid} not found or inaccessible` });
  }
});

app.get('/api/forensic', async (req, res) => {
  try {
    const top = await runCmd('ps -eo pid,pcpu,pmem,args --sort=-pcpu | head -20');
    const asciinema = await runCmd('pgrep -a asciinema || true');
    const loadavg = fs.readFileSync('/proc/loadavg', 'utf8').trim();
    const meminfo = fs.readFileSync('/proc/meminfo', 'utf8').trim();
    const cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8').trim();
    const highCpu = await runCmd("ps -eo pid,pcpu,args --sort=-pcpu | awk '$2 > 80.0' | head -10 || true");
    res.json({
      timestamp: new Date().toISOString(),
      loadavg,
      meminfo,
      cpuinfo,
      top_processes: top,
      asciinema_processes: asciinema,
      high_cpu_processes: highCpu,
      system: {
        hostname: os.hostname(),
        platform: os.platform(),
        release: os.release(),
        uptime: os.uptime(),
        totalmem: os.totalmem(),
        freemem: os.freemem(),
        cpus: os.cpus().length,
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', message: 'Forensic Dashboard backend is running' });
});

app.get('/api/data', (req, res) => {
  res.json({
    message: 'Hello from the forensic dashboard!',
    timestamp: new Date().toISOString(),
    items: ['Process Tree', 'CPU/Memory', 'Forensic Audit']
  });
});

app.listen(port, () => {
  console.log(`Forensic Dashboard backend listening on port ${port}`);
});
