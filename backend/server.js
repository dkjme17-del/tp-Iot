const path = require("path");
const express = require("express");
const { WebSocketServer } = require("ws");
const Broker = require("./broker");

const {
  PORT = "3000",
  HISTORY_SIZE = "500",
} = process.env;

const historySize = parseInt(HISTORY_SIZE, 10) || 500;
const history = [];
const lastByDevice = new Map();

const broker = new Broker();
const app = express();
app.use(express.static(path.join(__dirname, "public")));

app.get("/api/last", (req, res) => {
  res.json({
    brokerConnected: broker.connected,
    devices: [...lastByDevice.values()],
  });
});

app.get("/api/history", (req, res) => {
  const n = Math.min(500, parseInt(req.query.n, 10) || historySize);
  res.json(history.slice(-n));
});

app.get("/healthz", (req, res) => {
  res.status(broker.connected ? 200 : 503).json({ broker: broker.connected ? "up" : "down" });
});

const server = app.listen(PORT, () => {
  console.log(`[http] dashboard disponible sur http://0.0.0.0:${PORT}`);
});

const wss = new WebSocketServer({ server, path: "/ws" });

function broadcast(obj) {
  const msg = JSON.stringify(obj);
  for (const ws of wss.clients) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

broker.on("reading", (reading) => {
  history.push(reading);
  if (history.length > historySize) history.shift();
  lastByDevice.set(reading.deviceId, reading);
  broadcast({ type: "reading", reading });
});

broker.on("status", (up) => {
  console.log(`[broker] statut: ${up ? "CONNECTE" : "DECONNECTE"}`);
  broadcast({ type: "status", brokerConnected: up });
});

wss.on("connection", (ws) => {
  ws.send(JSON.stringify({
    type: "snapshot",
    brokerConnected: broker.connected,
    readings: history.slice(-historySize),
  }));
});

console.log(`[backend] historique memoire: ${historySize} mesures max`);
