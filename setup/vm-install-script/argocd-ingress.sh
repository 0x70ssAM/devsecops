#!/usr/bin/env bash
set -e

DOMAIN="devsecops.switzerlandnorth.cloudapp.azure.com"

echo "=== Installing NGINX Ingress Controller ==="

kubectl create namespace ingress-nginx 2>/dev/null || true

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.hostNetwork=true \
  --set controller.kind=DaemonSet \
  --set controller.service.enabled=false \
  --set controller.admissionWebhooks.enabled=false

echo "Waiting for ingress controller..."
kubectl rollout status daemonset ingress-nginx-controller -n ingress-nginx --timeout=300s

echo "=== Configure ArgoCD to run behind ingress ==="

kubectl -n argocd patch configmap argocd-cmd-params-cm \
  -p '{"data":{"server.insecure":"true"}}'

kubectl -n argocd rollout restart deployment argocd-server

sleep 15

echo "=== Creating self-signed TLS certificate ==="

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout argocd.key \
  -out argocd.crt \
  -subj "/CN=${DOMAIN}/O=DevSecOps"

kubectl -n argocd create secret tls argocd-tls \
  --key argocd.key \
  --cert argocd.crt \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Creating ArgoCD ingress ==="

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${DOMAIN}
    secretName: argocd-tls
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

echo
echo "========================================="
echo " ArgoCD is Ready!"
echo
echo " URL:"
echo " http://${DOMAIN}"
echo " https://${DOMAIN}"
echo
echo " Username: admin"
echo -n " Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
echo "========================================="
