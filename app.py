import psutil
import os
import time
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
  .bar { height: 100%; border-radius: 99px; transition: width 0.8s ease; }
  .bar-green { background: #22c55e; }
  .bar-yellow { background: #eab308; }
  .bar-red { background: #ef4444; }
  .section-title { font-size: 0.85rem; color: #666; margin-bottom: 0.75rem; }
  .disk-row { background: #1a1a1a; border: 0.5px solid #2a2a2a; border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem; }
  .disk-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
  .disk-name { font-size: 0.85rem; font-weight: 500; }
  .disk-pct { font-size: 0.85rem; color: #666; }
  .footer { font-size: 0.75rem; color: #444; text-align: right; margin-top: 1rem; }
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
<p class="footer" id="disk-refresh"></p>

<script>
let diskData = [];
let diskCountdown = 120;

function barColor(pct) {
  if (pct < 70) return 'bar-green';
  if (pct < 85) return 'bar-yellow';
  return 'bar-red';
}

function fmt(bytes) {
  if (bytes >= 1e9) return (bytes/1e9).toFixed(1) + ' GB';
  return (bytes/1e6).toFixed(0) + ' MB';
}

function renderMetrics(d) {
  const metrics = [
    { label: 'CPU', value: d.cpu.toFixed(0) + '%', sub: d.cores + ' núcleos', pct: d.cpu },
    { label: 'Memória', value: d.mem_pct.toFixed(0) + '%', sub: fmt(d.mem_used) + ' / ' + fmt(d.mem_total), pct: d.mem_pct },
    { label: 'Disco principal', value: d.disk_pct.toFixed(0) + '%', sub: fmt(d.disk_used) + ' / ' + fmt(d.disk_total), pct: d.disk_pct },
    { label: 'Uptime', value: d.uptime_h + 'h', sub: d.uptime_days + ' dias online', pct: null },
  ];
  document.getElementById('metrics').innerHTML = metrics.map(m => `
    <div class="card">
      <div class="card-label">${m.label}</div>
      <div class="card-value">${m.value}</div>
      <div class="card-sub">${m.sub}</div>
      ${m.pct !== null ? `<div class="bar-wrap"><div class="bar ${barColor(m.pct)}" style="width:${m.pct}%"></div></div>` : ''}
    </div>
  `).join('');
}

function renderDisks(disks) {
  document.getElementById('disks').innerHTML = disks.map(d => `
    <div class="disk-row">
      <div class="disk-header">
        <span class="disk-name">${d.mountpoint}</span>
        <span class="disk-pct">${fmt(d.free)} livres &bull; ${d.percent.toFixed(0)}%</span>
      </div>
      <div class="bar-wrap"><div class="bar ${barColor(d.percent)}" style="width:${d.percent}%"></div></div>
    </div>
  `).join('');
}

async function loadMetrics() {
  try {
    const r = await fetch('/api/metrics');
    const d = await r.json();
    renderMetrics(d);
    document.getElementById('last-update').textContent =
      'Última atualização: ' + new Date().toLocaleTimeString('pt-BR');
  } catch(e) {}
}

async function loadDisks() {
  try {
    const r = await fetch('/api/disks');
    const d = await r.json();
    diskData = d.disks;
    renderDisks(diskData);
    diskCountdown = 120;
  } catch(e) {}
}

function diskTick() {
  diskCountdown--;
  document.getElementById('disk-refresh').textContent =
    'Discos atualizam em ' + diskCountdown + 's';
  if (diskCountdown <= 0) loadDisks();
}

loadMetrics();
loadDisks();
setInterval(loadMetrics, 5000);
setInterval(diskTick, 1000);
</script>
</body>
</html>"""

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/api/metrics')
def metrics():
    cpu = psutil.cpu_percent(interval=0.5)
    cores = psutil.cpu_count()
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    uptime_s = int(time.time() - psutil.boot_time())
    return jsonify({
        'cpu': cpu,
        'cores': cores,
        'mem_pct': mem.percent,
        'mem_used': mem.used,
        'mem_total': mem.total,
        'disk_pct': disk.percent,
        'disk_used': disk.used,
        'disk_total': disk.total,
        'uptime_h': (uptime_s // 3600) % 24,
        'uptime_days': uptime_s // 86400,
    })

@app.route('/api/disks')
def disks():
    result = []
    seen = set()
    for part in psutil.disk_partitions(all=False):
        if part.fstype == '' or part.mountpoint in seen:
            continue
        if any(x in part.mountpoint for x in ['/etc/', '/proc', '/sys', '/dev', '/run']):
            continue
        try:
            usage = psutil.disk_usage(part.mountpoint)
            result.append({
                'mountpoint': part.mountpoint,
                'total': usage.total,
                'used': usage.used,
                'free': usage.free,
                'percent': usage.percent,
            })
            seen.add(part.mountpoint)
        except:
            pass
    return jsonify({'disks': result})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
