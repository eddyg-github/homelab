#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
EP=http://localhost:4567
kubectl create ns lstest --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata: {name: localstack, namespace: lstest}
spec:
  replicas: 1
  selector: {matchLabels: {app: localstack}}
  template:
    metadata: {labels: {app: localstack}}
    spec:
      containers:
        - name: localstack
          image: localstack/localstack:3.0.2
          ports: [{containerPort: 4566}]
          env:
            - {name: SERVICES, value: "s3,sqs,lambda,logs,dynamodb,iam,apigateway,sts,cloudwatch"}
            - {name: DEBUG, value: "1"}
          readinessProbe: {httpGet: {path: /_localstack/health, port: 4566}, periodSeconds: 10, failureThreshold: 30}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 1536Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: localstack, namespace: lstest}
spec: {selector: {app: localstack}, ports: [{port: 4566, targetPort: 4566}]}
Y
echo "== 1) Esperando el pod (puede tardar varios minutos) =="
kubectl -n lstest rollout status deploy/localstack --timeout=600s >/dev/null 2>&1 && ok "localstack Ready en k3s" || { bad "no arrancó"; kubectl -n lstest logs deploy/localstack --tail=20; kubectl delete ns lstest --wait=false >/dev/null; exit 1; }
kubectl -n lstest port-forward svc/localstack 4567:4566 >/tmp/pf-ls.log 2>&1 & PF=$!
sleep 4
echo "== 2) S3, SQS y DynamoDB =="
aws --endpoint-url $EP s3 mb s3://prueba >/dev/null 2>&1 && ok "S3" || bad "S3"
aws --endpoint-url $EP sqs create-queue --queue-name cola-prueba >/dev/null 2>&1 && ok "SQS" || bad "SQS"
aws --endpoint-url $EP dynamodb create-table --table-name t --attribute-definitions AttributeName=id,AttributeType=S --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 && ok "DynamoDB" || bad "DynamoDB"
echo "== 3) Lambda =="
cd /tmp && python3 - <<'PY'
import zipfile
z=zipfile.ZipFile('/tmp/fn.zip','w'); z.writestr('index.py','def handler(e,c):\n    return {"ok": True, "echo": e}\n'); z.close()
PY
aws --endpoint-url $EP lambda create-function --function-name hola --runtime python3.11 --handler index.handler --zip-file fileb:///tmp/fn.zip --role arn:aws:iam::000000000000:role/r >/tmp/lcreate.txt 2>&1 && ok "create-function aceptado" || { bad "create-function:"; head -c 400 /tmp/lcreate.txt; }
sleep 20
aws --endpoint-url $EP lambda invoke --function-name hola --payload '{"x":1}' --cli-binary-format raw-in-base64-out /tmp/out.json >/tmp/linvoke.txt 2>&1
echo "   respuesta: $(head -c 300 /tmp/linvoke.txt | tr '\n' ' ')"
echo "   salida de la función: $(head -c 200 /tmp/out.json 2>/dev/null)"
grep -q '"ok": true' /tmp/out.json 2>/dev/null && ok "LAMBDA FUNCIONA en k3s" || bad "Lambda NO funciona en k3s. Motivo en el log:"
kubectl -n lstest logs deploy/localstack --tail=300 | grep -i -E 'docker|executor|lambda.*(error|fail)' | tail -4 | cut -c1-220
kill $PF 2>/dev/null
kubectl delete ns lstest --wait=false >/dev/null && ok "namespace de prueba borrado"
