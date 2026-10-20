# Station de mesure connectée dans le cloud

**ESATIC — Groupe 2 · Remise : 20/10/2026**

Surveillance à distance de la température et de l'humidité des locaux : un capteur
(**simulé**) publie ses mesures vers un broker MQTT hébergé sur **AWS**, et un
**tableau de bord temps réel** les affiche depuis n'importe quel navigateur,
accessibles depuis Internet.

## Livrables

| Livrable | Lien |
|---|---|
| Code source | https://github.com/dkjme17-del/tp-Iot |
| Image Docker Hub (capteur) | https://hub.docker.com/r/dkjme17/esatic-sensor |
| Tableau de bord en ligne | http://54.227.2.193:3000 |
| Compte rendu | ce document |

## Architecture

```
┌─────────────────┐   MQTT/TLS 8883    ┌──────────────────────────────┐
│   CAPTEUR       │  (mTLS, X.509)     │   AWS IoT Core               │
│   simulé        │ ─────────────────▶ │   broker MQTT managé         │
│   (conteneur    │  topic:            │   topic esatic/+/mesures     │
│    Docker)      │  esatic/station-01 │                              │
└─────────────────┘  /mesures          └──────────────┬───────────────┘
                                                      │ MQTT/TLS (abonnement)
        Internet / navigateur                        ▼
┌─────────────────┐   WebSocket    ┌──────────────────────────────────┐
│  Dashboard      │ ◀────────────▶ │  EC2 t2.micro (Amazon Linux)     │
│  (navigateur)   │   temps réel   │  Docker Compose :                │
│  Chart.js       │                │   ├─ backend (Express + ws)      │
└─────────────────┘                │   └─ (image capteur Docker Hub)  │
                                   └──────────────────────────────────┘
```

**Flux d'une mesure** : `capteur → publish MQTT (QoS 1, retain) → AWS IoT Core
→ backend (abonné) → WebSocket → graphique du navigateur en < 1 s`.

## Choix techniques (justification)

### 1. MQTT comme protocole de transport
L'énoncé l'impose, et c'est le choix correct : MQTT est un protocole **léger
publish/subscribe** pensé pour l'IoT (faible bande passante, reconnexion
automatique, QoS, messages *retain* = le dashboard obtient la dernière mesure
même s'il se connecte après le capteur). Alternative HTTP : chaque mesure
demanderait une requête, pas de diffusion multiple, pas de gestion native des
désconnections.

### 2. AWS IoT Core comme broker (plutôt qu'un Mosquitto sur EC2)
- **Service managé** : pas de VM à maintenir pour le broker, pas de
  patch/OS/uptime à gérer — le point faible d'une approche « Mosquitto à la
  main sur une EC2 ».
- **Sécurité native** : authentification **mTLS par certificats X.509** par
  thing + **politique IoT** limitant chaque acteur au strict nécessaire
  (publish sur `esatic/*`, rien d'autre).
- **Scalabilité et fiabilité** : géré par AWS (disponibilité multi-AZ), quota
  gratuit généreux pour ce volume de messages (1 mesure / 3–5 s ≈ 17 k
  messages/mois, bien sous les 100 k offerts).
- Le broker étant managé (serverless), la **VM EC2 ne sert qu'au dashboard** :
  c'est elle qui reçoit le port ouvert vers Internet.

### 3. Node.js pour le capteur et le backend
- **Un seul langage** sur toute la chaîne → moins d'erreurs, démo plus fluide.
- `mqtt.js` gère à la fois l'ATS d'IoT Core (TLS + certificats) et un
  Mosquitto local : **le même code tourne en dev et en prod**, seul un
  variable d'environnement change.
- WebSocket natif côté serveur (`ws`) : le dashboard pousse les mesures
  instantanément, **pas de polling** (moins de charge, rendu réel).

### 4. Docker pour chaque composant (exigence)
- Chaque composant = **une image** : `esatic-sensor` (Docker Hub),
  `esatic-dashboard` (build sur l'EC2), Mosquitto (dev local).
- **Équivalence dev/prod** : `local-dev/docker-compose.yml` fait tourner toute
  la chaîne sur une machine avec un broker local ; `deploy/` utilise les mêmes
  images mais pointe vers IoT Core. Zéro « ça marche sur ma machine ».
- Déploiement reproductible en **une commande** : `docker compose up -d`.

### 5. Dashboard Express + WebSocket + Chart.js
- Un serveur statique minimal qui relaie les mesures en WebSocket et expose
  une API REST simple (`/api/last`, `/api/history`) pour usage externe.
- Chart.js en CDN : zéro build toolchain, un seul déploiement à faire.
- L'historique est gardé **en mémoire** (500 mesures) : suffisant pour la
  démo, et évite une base de données non demandée par l'énoncé.

### 6. Hébergement de la dashboard
Sur **la même EC2** (free tier t2.micro) que celle qui reçoit le flux IoT :
une seule URL à donner, un seul compte, un coût nul dans la limite free tier.
Le port **3000** est ouvert dans le security group — c'est l'URL du livrable.

## Structure du dépôt

```
esatic-station-iot/
├── sensor/            # Capteur simulé (Node.js, publie MQTT) + Dockerfile
├── backend/           # Express + WebSocket + abonnement MQTT + dashboard web
├── local-dev/         # docker-compose de développement (Mosquitto local)
├── deploy/            # docker-compose de production (AWS IoT Core)
│   └── .env.example   # variables d'environnement de prod
├── aws/
│   ├── setup-iot.sh   # provisionne IoT Core (thing, policy, certs, S3)
│   └── launch-ec2.sh  # lance l'EC2 du dashboard (cloud-init complet)
└── README.md
```

## Démarrage local (développement)

Prérequis : Docker + Docker Compose.

```bash
cd local-dev
docker compose up -d --build
# Dashboard : http://localhost:3000
# Arrêt :    docker compose down
```

Trois conteneurs démarrent : `mosquitto` (broker local), `sensor` (mesures
toutes les 3 s), `backend` (abonné + serveur web).

## Déploiement sur AWS (production)

Ordre exact (à faire depuis **AWS CloudShell**, qui fournit l'AWS CLI déjà
authentifié) :

```bash
# 0. Pousser le code sur GitHub (depuis la machine de dev)
git push origin main

# 1. Provisionner IoT Core (thing + policy + certificat + bucket S3)
git clone https://github.com/dkjme17-del/tp-Iot.git
cd tp-Iot
bash aws/setup-iot.sh
#   → génère deploy/.env (endpoint ATS) et une URL pré-signée des certificats

# 2. Lancer l'EC2 (security group, key pair, cloud-init Docker + compose)
bash aws/launch-ec2.sh https://github.com/dkjme17-del/tp-Iot.git
#   → affiche l'URL du tableau de bord : http://<IP>:3000
```

Le `user-data` de l'EC2 installe Docker, clone le dépôt, télécharge les
certificats depuis S3 (URL pré-signée, valable 7 jours), puis exécute
`docker compose -f deploy/docker-compose.prod.yml up -d`.

> ⚠️ **Coûts** : t2.micro est éligible au free tier (12 mois). **Terminer
> l'instance après la démo** : `aws ec2 terminate-instances --instance-ids <id>`.

### Publication de l'image du capteur sur Docker Hub

L'image est déjà publiée : [`dkjme17/esatic-sensor`](https://hub.docker.com/r/dkjme17/esatic-sensor).

```bash
cd sensor
docker build -t dkjme17/esatic-sensor:latest .
docker push dkjme17/esatic-sensor:latest
```

`DOCKERHUB_USER=dkjme17` (déjà renseigné dans `deploy/.env.example`) indique à
l'EC2 quelle image tirer depuis Docker Hub.

## API

| Endpoint | Description |
|---|---|
| `GET /` | Tableau de bord temps réel |
| `GET /api/last` | Dernière mesure par capteur + état du broker |
| `GET /api/history?n=100` | `n` dernières mesures |
| `GET /healthz` | `200` si le backend est abonné au broker, `503` sinon |
| `WS /ws` | Flux temps réel : `snapshot`, `reading`, `status` |

Format de mesure (JSON, topic `esatic/<deviceId>/mesures`) :

```json
{"deviceId":"station-01","seq":42,"temperature":25.6,"humidity":58.4,"ac":false,"ts":"2026-10-20T09:05:55.503Z"}
```

## Sécurité

- **mTLS** : certificat X.509 unique par thing, clé privée jamais sur le
  réseau ; la policy n'autorise que `iot:Connect`, `Publish`, `Subscribe`,
  `Receive` sur `esatic/*`.
- Secrets hors Git : `deploy/.env` et `deploy/certs/` sont `.gitignore`.
- **Limite assumée pour la démo** : les certificats transitent par une URL
  pré-signée S3 (7 jours) dans le cloud-init — en production, on utiliserait
  un **rôle IAM** attaché à l'instance (lecture du bucket uniquement) et le
  **verrouillage du port 22** à l'IP du développeur.

## Pistes d'évolution

- **Vrai capteur (bonus)** : un ESP32/Raspberry Pi + DHT22 publie sur le même
  topic avec le même certificat — **aucun changement côté dashboard**
  (l'architecture publier/consommateur l'absorbe).
- Persistance des mesures (Timestream/InfluxDB) pour l'historique long terme.
- Alertes (SNS/Email) seuil température.
- Dashboard derrière HTTPS (Caddy + Let's Encrypt) et scaling (ALB + ECS).

## Plan de démonstration (10 min)

1. **Contexte & besoins** ESATIC, exigences de l'énoncé (2 min)
2. **Architecture** et flux d'une mesure (schéma ci-dessus) (2 min)
3. **Démonstration live** : mesures qui arrivent, graphique temps réel,
   arrêt du capteur → alerte « capteur inactif », redémarrage (3 min)
4. **Justification des choix** : IoT Core, MQTT, Docker, WebSocket (2 min)
5. **Livrables** : GitHub, Docker Hub, URL publique, pistes d'évolution (1 min)
