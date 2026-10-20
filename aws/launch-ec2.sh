#!/usr/bin/env bash
# =============================================================================
# launch-ec2.sh — Lance l'instance EC2 qui herberge le tableau de bord
#
# Prerequis : aws/setup-iot.sh execute (deploy/.env genere), depot GitHub
# public pousse.
#
# A executer dans AWS CloudShell, depuis la racine du depot :
#   bash aws/launch-ec2.sh https://github.com/<user>/<repo>.git
#
# Cree : key pair SSH, security group (22 + 3000), instance t2.micro AL2023
# avec un user-data qui installe Docker, clone le depot, telecharge les
# certs IoT et demarre docker compose. La cle SSH est uploadee en S3
# (URL pre-signee affichee en fin de script).
# =============================================================================
set -euo pipefail

REPO_URL="${1:-}"
[[ -n "${REPO_URL}" ]] || { echo "Usage: $0 https://github.com/<user>/<repo>.git"; exit 1; }
[[ -f deploy/.env ]] || { echo "ERREUR: deploy/.env absent — lancez d'abord aws/setup-iot.sh"; exit 1; }

get_env() {
  { grep -E "^$1=" deploy/.env | head -n 1 | cut -d= -f2- | tr -d "'\"" || true; }
}
REGION="$(get_env AWS_REGION)"
ENDPOINT="$(get_env MQTT_ENDPOINT)"
CERTS_URL="$(get_env CERTS_URL)"
DOCKERHUB_USER="$(get_env DOCKERHUB_USER)"
[[ -n "${REGION}" ]] || REGION=$(aws configure get region 2>/dev/null || true)
DOCKERHUB_USER="${DOCKERHUB_USER:-dkjme17}"
[[ -n "${REGION}" ]] || { echo "ERREUR: region AWS inconnue (deploy/.env, AWS_REGION, aws configure)"; exit 1; }
[[ -n "${ENDPOINT}" ]] || { echo "ERREUR: MQTT_ENDPOINT absent de deploy/.env — relancez aws/setup-iot.sh"; exit 1; }
[[ -n "${CERTS_URL}" ]] || { echo "ERREUR: CERTS_URL absent de deploy/.env — relancez aws/setup-iot.sh"; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="esatic-iot-certs-${ACCOUNT}"
KEY_NAME="esatic-iot-keypair"
SG_NAME="esatic-iot-sg"
WORKDIR="$(pwd)/ec2-out"
mkdir -p "${WORKDIR}"

echo "==> [1/5] AMI Amazon Linux 2023 + VPC par defaut"
AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
[[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]] || { echo "ERREUR: pas de VPC par defaut"; exit 1; }

echo "==> [2/5] Key pair SSH (copie stockee dans S3)"
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
  echo "    key pair deja existant, generation d'une nouvelle cle nommee ${KEY_NAME}-$(date +%s)"
  KEY_NAME="${KEY_NAME}-$(date +%s)"
fi
aws ec2 create-key-pair --key-name "${KEY_NAME}" --query 'KeyMaterial' --output text \
  > "${WORKDIR}/ec2-key.pem"
chmod 600 "${WORKDIR}/ec2-key.pem"
aws s3 cp "${WORKDIR}/ec2-key.pem" "s3://${BUCKET}/ec2-key.pem" >/dev/null
KEY_URL=$(aws s3 presign "s3://${BUCKET}/ec2-key.pem" --expires-in 604800)

echo "==> [3/5] Security group: SSH (22) + dashboard (3000)"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SG_NAME}" \
    --description "ESATIC station IoT - SSH + dashboard" \
    --vpc-id "${VPC_ID}" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 3000 --cidr 0.0.0.0/0
fi

echo "==> [4/5] Script cloud-init (user-data)"
cat > "${WORKDIR}/user-data.sh" <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y docker git
systemctl enable --now docker
mkdir -p /opt/station
cd /opt/station
git clone ${REPO_URL} .
curl -fL "${CERTS_URL}" -o /tmp/certs.tar.gz
tar xzf /tmp/certs.tar.gz -C deploy/
cat > deploy/.env <<ENV
MQTT_ENDPOINT=${ENDPOINT}
MQTT_TOPIC_PUB=esatic/station-01/mesures
DEVICE_ID=station-01
INTERVAL_MS=5000
DASHBOARD_PORT=3000
DOCKERHUB_USER=${DOCKERHUB_USER}
ENV
docker compose --env-file deploy/.env -f deploy/docker-compose.prod.yml build backend
docker compose --env-file deploy/.env -f deploy/docker-compose.prod.yml up -d
EOF

echo "==> [5/5] Lancement de l'instance (free tier)"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
if [[ -z "${INSTANCE_TYPE}" ]]; then
  FT_LIST=$(aws ec2 describe-instance-types --filters "Name=free-tier-eligible,Values=true" --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null || true)
  echo "    types free tier disponibles: ${FT_LIST:-aucun}"
  if [[ " ${FT_LIST} " == *" t3.micro "* ]]; then
    INSTANCE_TYPE=t3.micro
  elif [[ " ${FT_LIST} " == *" t2.micro "* ]]; then
    INSTANCE_TYPE=t2.micro
  elif [[ -n "${FT_LIST}" && "${FT_LIST}" != "None" ]]; then
    INSTANCE_TYPE=$(echo "${FT_LIST}" | awk '{print $1}')
  else
    echo "ERREUR: aucun type d'instance free tier eligible dans cette region."
    echo "  Solution A: choisir une region ou le free tier est dispo (ex: eu-west-1)"
    echo "  Solution B: dans la console EC2 > Settings > Instance launch, decocher"
    echo "             't2.micro et t3.micro only' / free tier filter, puis relancer"
    exit 1
  fi
fi
echo "    type d'instance: ${INSTANCE_TYPE}"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "${AMI}" \
  --instance-type "${INSTANCE_TYPE}" \
  --key-name "${KEY_NAME}" \
  --security-group-ids "${SG_ID}" \
  --user-data "file://${WORKDIR}/user-data.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=esatic-station-dash}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "    instance ${INSTANCE_ID} en cours de demarrage, attente des checks (~2-3 min)..."
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<EOF

==========================================================================
 EC2 prete.
   Instance     : ${INSTANCE_ID} (${PUBLIC_IP})
   Tableau de bord : http://${PUBLIC_IP}:3000
   Cle SSH      : telechargez-la avec l'URL (valable 7 jours) :
                  ${KEY_URL}
   Connexion    : ssh -i ec2-key.pem ec2-user@${PUBLIC_IP}
                  (sudo docker compose -f /opt/station/deploy/docker-compose.prod.yml logs -f)
==========================================================================
 Pour arreter (eviter les frais) :
   aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}
==========================================================================
EOF
