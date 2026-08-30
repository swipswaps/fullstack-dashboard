const express = require('express');
const cors = require('cors');
const app = express();
const port = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', message: 'Backend is running' });
});

app.get('/api/data', (req, res) => {
  res.json({
    message: 'Hello from the backend!',
    timestamp: new Date().toISOString(),
    items: ['Item 1', 'Item 2', 'Item 3']
  });
});

app.listen(port, () => {
  console.log(`Backend listening on port ${port}`);
});
