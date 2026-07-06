import psutil
import os
from flask import Flask, jsonify, render_template_string

app = Flask(__name__)

HTML = """<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Monitor do Servidor</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f0f0f; color: #e8e8e8; min-height: 100vh; padding: 2rem; }
  h1 { font-size: 1.25rem; font-weight: 500; color: #fff; margin-bottom: 0.25rem; }
  .subtitle { font-size: 0.85rem; color: #666; margin-bottom: 2rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
  .card { background: #1a1a1a; border: 0.5px solid #2a2a2a; border-radius: 12px; padding: 1.25rem; }
  .card-label { font-size: 0.75rem; color: #666; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem; }
  .card-value { font-size: 2rem; font-weight: 500; }
  .card-sub { font-size: 0.8rem; color: #666; margin-top: 0.25rem; }
  .bar-wrap { background: #2a2a2a; border-radius: 99px; height: 6px; margin-top: 0.75rem; overflow: hidden; }
  .bar { height: 100%; border-radius: 99px; transition: width 0.5s; }
  .bar-green { background: #22c55e; }
  .bar-yellow { background: #eab308; }
  .bar-red { background: #ef4444; }
  .section-title { font-size: 0.85rem; color: #666; margin-bottom: 0.75rem; }
  .disk-row { background: #1a1a1a; border: 0.5px solid #2a2a2a; border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem; }
  .disk-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
  .disk-name { font-size: 0.85rem; font-weight: 500; }
  .disk-pct { font-size: 0.85rem; color: #666; }
  .refreshing { font-size: 0.75rem; color: #444; text-align: right; }
  .dot { display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: #22c55e; margin-right: 6px; animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }
</style>
</head>
<body>
<h1><span class="dot"></span>Monitor do Servidor</h1>
<p class="subtitle" id="last-update">Carregando...</p>

<div class="grid" id="metrics"></div>
<p class="section-title">Discos</p>
<div id="disks"></div>
<p class="refreshing" id="next-refresh"></p>

<script>
let countdown = 600;

function color(pct) {
  if (pct < 70) return 'bar-green';
  if (pct < 85) return 'bar-yellow';
  return 'bar-red';
}

function fmt(bytes) {
  if (bytes >= 1e9) return (bytes/1e9).toFixed(1) + ' GB';
  return (bytes/1e6).toFixed(0) + ' MB';
}

async function load() {
  const r = await fetch('/api/stats');
  const d = await r.json();

  document.getElementById('last-update').textContent =
    'Última atualização: ' + new Date().toLocaleTimeString('pt-BR');

  const metrics = [
    { label: 'CPU', value: d.cpu.percent.toFixed(0) + '%', sub: d.cpu.cores + ' núcleos', pct: d.cpu.percent },
    { label: 'Memória', value: d.memory.percent.toFixed(0) + '%', sub: fmt(d.memory.used) + ' / ' + fmt(d.memory.total), pct: d.memory.percent },
    { label: 'Disco principal', value: d.disk_root.percent.toFixed(0) + '%', sub: fmt(d.disk_root.used) + ' / ' + fmt(d.disk_root.total), pct: d.disk_root.percent },
    { label: 'Uptime', value: d.uptime_h + 'h', sub: d.uptime_days + ' dias online', pct: null },
  ];

  document.getElementById('metrics').innerHTML = metrics.map(m => `
    <div class="card">
      <div class="card-label">${m.label}</div>
      <div class="card-value">${m.value}</div>
      <div class="card-sub">${m.sub}</div>
      ${m.pct !== null ? `<div class="bar-wrap"><div class="bar ${color(m.pct)}" style="width:${m.pct}%"></div></div>` : ''}
    </div>
  `).join('');

  document.getElementById('disks').innerHTML = d.disks.map(disk => `
    <div class="disk-row">
      <div class="disk-header">
        <span class="disk-name">${disk.mountpoint}</span>
        <span class="disk-pct">${fmt(disk.free)} livres &bull; ${disk.percent.toFixed(0)}%</span>
      </div>
      <div class="bar-wrap"><div class="bar ${color(disk.percent)}" style="width:${disk.percent}%"></div></div>
    </div>
  `).join('');

  countdown = 600;
}

function tick() {
  countdown--;
  const min = Math.floor(countdown / 60);
  const sec = countdown % 60;
  document.getElementById('next-refresh').textContent =
    'Próxima atualização em ' + min + ':' + String(sec).padStart(2,'0');
  if (countdown <= 0) load();
}

load();
setInterval(tick, 1000);
</script>
</body>
</html>"""

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/api/stats')
def stats():
    cpu = psutil.cpu_percent(interval=1)
    cores = psutil.cpu_count()
    mem = psutil.virtual_memory()
    disk_root = psutil.disk_usage('/')
    boot = psutil.boot_time()
    import time
    uptime_s = int(time.time() - boot)
    uptime_h = uptime_s // 3600
    uptime_days = uptime_s // 86400

    disks = []
    for part in psutil.disk_partitions():
        try:
            usage = psutil.disk_usage(part.mountpoint)
            disks.append({
                'mountpoint': part.mountpoint,
                'total': usage.total,
                'used': usage.used,
                'free': usage.free,
                'percent': usage.percent,
            })
        except:
            pass

    return jsonify({
        'cpu': {'percent': cpu, 'cores': cores},
        'memory': {'percent': mem.percent, 'used': mem.used, 'total': mem.total, 'free': mem.free},
        'disk_root': {'percent': disk_root.percent, 'used': disk_root.used, 'total': disk_root.total, 'free': disk_root.free},
        'uptime_h': uptime_h % 24,
        'uptime_days': uptime_days,
        'disks': disks,
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
