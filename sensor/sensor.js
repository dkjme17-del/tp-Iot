const fs = require("fs");
const mqtt = require("mqtt");

const {
  MQTT_URL = "mqtt://localhost:1883",
  MQTT_TOPIC = "esatic/station-01/mesures",
  DEVICE_ID = "station-01",
  INTERVAL_MS = "5000",
  CERT_PATH,
  KEY_PATH,
  CA_PATH,
} = process.env;

const interval = Math.max(500, parseInt(INTERVAL_MS, 10) || 5000);

const CLIENT_SUFFIX = process.env.CLIENT_SUFFIX || Math.random().toString(36).slice(2, 8);
const options = {
  clientId: `sensor-${DEVICE_ID}-${CLIENT_SUFFIX}`,
  keepalive: 30,
  reconnectPeriod: 5000,
  connectTimeout: 15000,
  clean: true,
};

if (CERT_PATH && KEY_PATH && CA_PATH) {
  options.cert = fs.readFileSync(CERT_PATH);
  options.key = fs.readFileSync(KEY_PATH);
  options.ca = fs.readFileSync(CA_PATH);
}

console.log(`[sensor] ${DEVICE_ID} -> ${MQTT_URL} (topic: ${MQTT_TOPIC}, tous les ${interval}ms)`);

const client = mqtt.connect(MQTT_URL, options);

let seq = 0;
function publish() {
  seq += 1;
  const m = nextMeasurement(seq);
  client.publish(MQTT_TOPIC, JSON.stringify(m), { qos: 1, retain: true }, (err) => {
    if (err) console.error("[sensor] echec publication:", err.message);
    else console.log(`[sensor] #${m.seq} ${m.temperature}C ${m.humidity}%${m.ac ? " [clim]" : ""}`);
  });
}

let timer = null;

client.on("connect", () => {
  console.log("[sensor] connecte au broker MQTT");
  publish();
  if (!timer) timer = setInterval(publish, interval);
});
client.on("error", (err) => console.error("[sensor] erreur MQTT:", err.message));
client.on("offline", () => console.warn("[sensor] hors-ligne, tentative de reconnexion..."));

let temperature = 24 + Math.random() * 2;
let humidity = 55 + Math.random() * 5;
let acOn = false;

function nextMeasurement(seq) {
  const hour = new Date().getHours() + new Date().getMinutes() / 60;
  const dayCycle = Math.sin(((hour - 6) / 24) * 2 * Math.PI) * 2.5;

  temperature += (Math.random() - 0.5) * 0.4;
  if (!acOn && temperature > 28.5) acOn = true;
  if (acOn && temperature < 23.5) acOn = false;
  temperature += acOn ? -0.35 : 0.12;
  const target = 24 + dayCycle;
  temperature += (target - temperature) * 0.08;

  humidity += (Math.random() - 0.5) * 1.2 + (target - temperature) * 0.1;
  humidity = Math.min(80, Math.max(35, humidity));

  return {
    deviceId: DEVICE_ID,
    seq,
    temperature: Math.round(temperature * 10) / 10,
    humidity: Math.round(humidity * 10) / 10,
    ac: acOn,
    ts: new Date().toISOString(),
  };
}
