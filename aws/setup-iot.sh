#!/usr/bin/env bash
# =============================================================================
# setup-iot.sh — Provisionne AWS IoT Core pour la station de mesure ESATIC
#
# A executer dans AWS CloudShell (AWS CLI v2 deja configure), depuis la
# racine du depot clone :
#   git clone https://github.com/<user>/<repo>.git && cd <repo>
#   bash aws/setup-iot.sh
#
# Cree :
#   1. le thing IoT (jumeau numerique du capteur)
#   2. la politique IoT (autorisations MQTT minimales)
#   3. un certificat client X.509 (mTLS) + attaches policy/thing
#   4. un bucket S3 (chiffre) contenant certs.tar.gz
#   5. deploy/.env (endpoint ATS) et une URL pre-signee pour l'EC2
#
# Idempotent : re-execution sans erreur majeure, mais un re-lancement genere
# un nouveau certificat (l'ancien reste a desactiver si besoin).
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
[[ -n "${REGION}" ]] || { echo "ERREUR: definir AWS_REGION ou executer 'aws configure set region <region>'"; exit 1; }

THING="${THING_NAME:-esatic-station-01}"
POLICY="${POLICY_NAME:-esatic-dashboard-policy}"
TOPIC_PREFIX="${TOPIC_PREFIX:-esatic}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="esatic-iot-certs-${ACCOUNT}"
WORKDIR="$(pwd)/certs-out"

mkdir -p "${WORKDIR}"

echo "==> [1/6] Endpoint ATS du broker"
ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)
echo "    ${ENDPOINT}"

echo "==> [2/6] Thing IoT: ${THING}"
aws iot describe-thing --thing-name "${THING}" >/dev/null 2>&1 \
  || aws iot create-thing --thing-name "${THING}" >/dev/null

echo "==> [3/6] Politique IoT: ${POLICY}"
cat > "${WORKDIR}/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:Connect",
      "Resource": "arn:aws:iot:${REGION}:${ACCOUNT}:client/*"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Publish",
      "Resource": "arn:aws:iot:${REGION}:${ACCOUNT}:topic/${TOPIC_PREFIX}/*"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Subscribe",
      "Resource": "arn:aws:iot:${REGION}:${ACCOUNT}:topicfilter/${TOPIC_PREFIX}/*"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Receive",
      "Resource": "arn:aws:iot:${REGION}:${ACCOUNT}:topic/${TOPIC_PREFIX}/*"
    }
  ]
}
EOF
if aws iot create-policy --policy-name "${POLICY}" --policy-document "file://${WORKDIR}/policy.json" 2>"${WORKDIR}/policy.err"; then
  echo "    politique creee"
elif grep -q "ResourceAlreadyExistsException" "${WORKDIR}/policy.err"; then
  echo "    politique deja existante, on reutilise"
else
  echo "ERREUR: creation de la politique impossible:"
  cat "${WORKDIR}/policy.err"
  exit 1
fi

echo "==> [4/6] Certificat client X.509 (mTLS)"
CERT_ARN=$(aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile "${WORKDIR}/cert.pem" \
  --public-key-outfile "${WORKDIR}/public.pem" \
  --private-key-outfile "${WORKDIR}/private.key" \
  --query certificateArn --output text)
aws iot attach-policy --policy-name "${POLICY}" --target "${CERT_ARN}"
aws iot attach-thing-principal --thing-name "${THING}" --principal "${CERT_ARN}"
echo "    ${CERT_ARN}"

echo "==> [5/6] Racine CA Amazon + archive certs.tar.gz"
curl -fsSL https://www.amazontrust.com/repository/AmazonRootCA1.pem -o "${WORKDIR}/AmazonRootCA1.pem"
STAGE=$(mktemp -d)
mkdir -p "${STAGE}/certs"
cp "${WORKDIR}/cert.pem" "${WORKDIR}/private.key" "${WORKDIR}/AmazonRootCA1.pem" "${STAGE}/certs/"
tar -czf "${WORKDIR}/certs.tar.gz" -C "${STAGE}" certs

aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null || {
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
}
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3 cp "${WORKDIR}/certs.tar.gz" "s3://${BUCKET}/certs.tar.gz" >/dev/null
CERTS_URL=$(aws s3 presign "s3://${BUCKET}/certs.tar.gz" --expires-in 604800)

echo "==> [6/6] Generation de deploy/.env"
cat > deploy/.env <<EOF
MQTT_ENDPOINT='${ENDPOINT}'
MQTT_TOPIC_PUB='${TOPIC_PREFIX}/station-01/mesures'
DEVICE_ID='station-01'
INTERVAL_MS='5000'
DASHBOARD_PORT='3000'
AWS_REGION='${REGION}'
CERTS_URL='${CERTS_URL}'
EOF

cat <<EOF

==========================================================================
 IoT Core provisionne avec succes.
   Endpoint MQTT : mqtts://${ENDPOINT}:8883
   Thing         : ${THING}
   Policy        : ${POLICY}
   Certificat    : ${CERT_ARN}
   Bucket certs  : s3://${BUCKET}
   deploy/.env   : genere (ne pas le committer)
==========================================================================
 Suite (apres avoir push le code sur GitHub) :
   bash aws/launch-ec2.sh https://github.com/<user>/<repo>.git
==========================================================================
EOF
