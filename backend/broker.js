const fs = require("fs");
const { EventEmitter } = require("events");
const mqtt = require("mqtt");

const {
  MQTT_URL = "mqtt://localhost:1883",
  MQTT_TOPIC = "esatic/+/mesures",
  CERT_PATH,
  KEY_PATH,
  CA_PATH,
} = process.env;

class Broker extends EventEmitter {
  constructor() {
    super();
    this.connected = false;

    const options = {
      clientId: `dashboard-backend-${process.pid}`,
      reconnectPeriod: 5000,
      connectTimeout: 10000,
    };
    if (CERT_PATH && KEY_PATH && CA_PATH) {
      options.cert = fs.readFileSync(CERT_PATH);
      options.key = fs.readFileSync(KEY_PATH);
      options.ca = fs.readFileSync(CA_PATH);
    }

    this.client = mqtt.connect(MQTT_URL, options);

    this.client.on("connect", () => {
      console.log(`[broker] connecte a ${MQTT_URL}`);
      this.client.subscribe(MQTT_TOPIC, { qos: 1 }, (err) => {
        if (err) console.error("[broker] echec abonnement:", err.message);
        else console.log(`[broker] abonne a ${MQTT_TOPIC}`);
      });
      this.connected = true;
      this.emit("status", true);
    });

    this.client.on("close", () => {
      if (this.connected) console.warn("[broker] connexion fermee");
      this.connected = false;
      this.emit("status", false);
    });

    this.client.on("error", (err) => {
      console.error("[broker] erreur:", err.message);
    });

    this.client.on("message", (topic, payload) => {
      try {
        const reading = JSON.parse(payload.toString());
        reading.topic = topic;
        this.emit("reading", reading);
      } catch {
        console.warn("[broker] message non-JSON ignore sur", topic);
      }
    });
  }
}

module.exports = Broker;
