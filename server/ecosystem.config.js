module.exports = {
  apps: [{
    name: 'adhd-flask',
    script: '/home/ubuntu/adhd_project/venv/bin/python',
    args: '/home/ubuntu/adhd_project/app.py',
    cwd: '/home/ubuntu/adhd_project',
    env: {
      MOONSHOT_API_KEY: '***REDACTED_MOONSHOT_KEY***'
    },
    autorestart: true,
    watch: false,
    max_memory_restart: '300M',
    restart_delay: 3000
  }]
}
