const fs = require('fs');
const path = require('path');

function loadEnvFile(filePath) {
  const env = {};
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    for (const rawLine of content.split('\n')) {
      const line = rawLine.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let value = line.slice(eq + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      if (key) env[key] = value;
    }
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn('[ecosystem] 读取 env 文件失败:', filePath, err.message);
    } else {
      console.warn('[ecosystem] env 文件不存在，应用将使用占位 key:', filePath);
    }
  }
  return env;
}

const envFile = process.env.ADHD_ENV_FILE
  || path.join(process.env.HOME || '/home/ubuntu', '.config/adhd-monitor.env');

module.exports = {
  apps: [{
    name: 'adhd-flask',
    script: '/home/ubuntu/ADHD_Monitor/server/.venv/bin/python',
    args: 'app.py',
    cwd: '/home/ubuntu/ADHD_Monitor/server',
    interpreter: 'none',
    env: loadEnvFile(envFile),
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    restart_delay: 3000,
    out_file: '/home/ubuntu/ADHD_Monitor/server/app.log',
    error_file: '/home/ubuntu/ADHD_Monitor/server/app.error.log',
    merge_logs: true,
    time: true
  }]
};
