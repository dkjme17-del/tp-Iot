const MAX_POINTS = 100;
const STALE_MS = 30000;

const $ = (id) => document.getElementById(id);

const chart = new Chart($("chart"), {
  type: "line",
  data: {
    labels: [],
    datasets: [
      {
        label: "Température (°C)",
        data: [],
        borderColor: "#f97316",
        backgroundColor: "rgba(249,115,22,0.12)",
        yAxisID: "y-temp",
        tension: 0.3,
        pointRadius: 0,
        borderWidth: 2,
        fill: true,
      },
      {
        label: "Humidité (%)",
        data: [],
        borderColor: "#38bdf8",
        backgroundColor: "rgba(56,189,248,0.08)",
        yAxisID: "y-hum",
        tension: 0.3,
        pointRadius: 0,
        borderWidth: 2,
      },
    ],
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    animation: { duration: 200 },
    interaction: { mode: "index", intersect: false },
    scales: {
      x: { ticks: { color: "#94a3b8", maxTicksLimit: 8 }, grid: { color: "rgba(148,163,184,0.1)" } },
      "y-temp": {
        position: "left",
        title: { display: true, text: "°C", color: "#f97316" },
        ticks: { color: "#f97316" },
        grid: { color: "rgba(148,163,184,0.1)" },
      },
      "y-hum": {
        position: "right",
        title: { display: true, text: "%", color: "#38bdf8" },
        ticks: { color: "#38bdf8" },
        grid: { drawOnChartArea: false },
      },
    },
    plugins: { legend: { labels: { color: "#e2e8f0" } } },
  },
});

let lastTs = null;

function fmtTime(iso) {
  return new Date(iso).toLocaleTimeString("fr-FR", { hour12: false });
}

function pushReading(r) {
  lastTs = new Date(r.ts);
  $("device-id").textContent = r.deviceId || "—";
  $("temp-value").textContent = r.temperature.toFixed(1);
  $("hum-value").textContent = r.humidity.toFixed(1);
  $("temp-meta").textContent = r.ac ? "climatisation active" : "confort normal";
  $("temp-meta").className = r.ac ? "card-meta cool" : "card-meta";
  $("last-update").textContent = `mesure de ${fmtTime(r.ts)}`;

  chart.data.labels.push(fmtTime(r.ts));
  chart.data.datasets[0].data.push(r.temperature);
  chart.data.datasets[1].data.push(r.humidity);
  if (chart.data.labels.length > MAX_POINTS) {
    chart.data.labels.shift();
    chart.data.datasets.forEach((d) => d.data.shift());
  }
  chart.update();
}

function setBadge(el, state, text) {
  el.textContent = text;
  el.className = `badge badge-${state}`;
}

function checkStale() {
  if (!lastTs) return;
  const age = Date.now() - lastTs.getTime();
  if (age > STALE_MS) {
    $("last-update").textContent = `dernière mesure il y a ${Math.round(age / 1000)}s — capteur inactif ?`;
    $("last-update").className = "card-meta warn";
    setBadge($("broker-badge"), "wait", "Capteur inactif");
  } else {
    $("last-update").className = "card-meta";
  }
  const now = new Date();
  $("clock").textContent = now.toLocaleTimeString("fr-FR", { hour12: false });
}
setInterval(checkStale, 2000);

function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.onopen = () => setBadge($("ws-badge"), "ok", "WebSocket connecté");
  ws.onclose = () => {
    setBadge($("ws-badge"), "err", "WebSocket coupé — reconnexion…");
    setTimeout(connect, 2000);
  };
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === "snapshot") {
      setBadge($("broker-badge"), msg.brokerConnected ? "ok" : "err",
        msg.brokerConnected ? "Broker MQTT connecté" : "Broker MQTT coupé");
      chart.data.labels = [];
      chart.data.datasets.forEach((d) => (d.data = []));
      for (const r of msg.readings) pushReading(r);
    } else if (msg.type === "reading") {
      pushReading(msg.reading);
    } else if (msg.type === "status") {
      setBadge($("broker-badge"), msg.brokerConnected ? "ok" : "err",
        msg.brokerConnected ? "Broker MQTT connecté" : "Broker MQTT coupé");
    }
  };
}
connect();
