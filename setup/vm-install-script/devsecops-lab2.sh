#!/bin/bash
export KUBECONFIG=/etc/kubernetes/admin.conf
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run this script with sudo"
  exit 1
fi

set -euo pipefail

########################################
# CONFIG
########################################
EMAIL="hossamibraheem2014@gmail.com"
K8S_VERSION="v1.35"
POD_CIDR="10.244.0.0/16"
MAX_RETRIES=5
SLEEP_SECONDS=15
########################################
# Helpers
########################################
log(){ echo -e "\n\033[1;32m[INFO]\033[0m $1"; }
warn(){ echo -e "\n\033[1;33m[WARN]\033[0m $1"; }


########################################
# Certificate Health Check + Retry Logic
########################################

check_cert() {

    NS="$1"
    CERT="$2"

    local retry=0

    echo ""
    echo "🔐 Checking certificate: $CERT (namespace: $NS)"
    echo "Max retries: $MAX_RETRIES"

    while [ "$retry" -lt "$MAX_RETRIES" ]; do

        STATUS=$(kubectl get certificate "$CERT" -n "$NS" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

        if [ "$STATUS" == "True" ]; then
            echo "✅ Certificate $CERT is Ready!"
            return 0
        fi

        echo "❌ Not Ready (Attempt $((retry+1))/$MAX_RETRIES)"
        sleep 5
        kubectl delete certificate "$CERT" -n "$NS" --ignore-not-found
        kubectl delete secret "$CERT" -n "$NS" --ignore-not-found

        sleep "$SLEEP_SECONDS"

        retry=$((retry+1))
    done

    echo "⚠ Certificate $CERT failed after $MAX_RETRIES retries"
    return 1
}

########################################
# Variables
########################################
PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://api.ipify.org)
NIP_IP=$(echo $PUBLIC_IP | tr '.' '-')

# ROOT
ROOT_DOMAIN="devsecops.switzerlandnorth.cloudapp.azure.com"
ROOT_TLS="portal-tls"
ROOT_NS="devsecops-portal"

## ARGOCD
ARGOCD_DOMAIN="argocd-${NIP_IP}.nip.io"
ARGOCD_TLS="argocd-tls"
ARGOCD_NS="argocd"

#JENKINS
JENKINS_DOMAIN="jenkins-${NIP_IP}.nip.io"
JENKINS_TLS="jenkins-tls"
JENKINS_NS="jenkins"

#TEKTON
TEKTON_DOMAIN="tekton-${NIP_IP}.nip.io"
TEKTON_TLS="tekton-tls"
TEKTON_NS="tekton-pipelines"

#SONARQUBE
SONARQUBE_DOMAIN="sonarqube-${NIP_IP}.nip.io"
SONARQUBE_TLS="sonarqube-tls"
SONARQUBE_NS="sonarqube"

#DEFECTDOJO
DEFECTDOJO_DOMAIN="defectdojo-${NIP_IP}.nip.io"
DEFECTDOJO_TLS="defectdojo-tls"
DEFECTDOJO_NS="defectdojo"

echo "Public IP: $PUBLIC_IP"
########################################
# SYSTEM PREP
########################################
log "Installing base packages"

sudo apt-get update -y
sudo apt-get install -y sshpass curl wget git jq ca-certificates gnupg gnupg-agent dirmngr lsb-release software-properties-common apt-transport-https bash-completion

########################################
# Build Tools
########################################
log "Installing Build Tools"

# Java + JDK
sudo apt-get install -y openjdk-17-jdk openjdk-21-jdk

# Maven
sudo apt-get install -y maven

# Gradle
sudo apt-get install -y gradle

# Node + npm (LTS)
sudo curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
sudo apt-get install -y nodejs

# Python3 + pip
sudo apt-get install -y python3 python3-pip python3-venv pipx

echo "Java version:"
java -version
echo "Maven version:"
mvn -version
echo "Gradle version:"
gradle -v
echo "Node version:"
node -v
echo "Python version:"
python3 --version

########################################
# NOTE: swap is intentionally left ON (see swap prerequisite set up before
# this script runs) — this host has far less RAM than the platform's
# intended sizing, so swap is kept as headroom and kubelet is told to
# tolerate it (failSwapOn: false + Swap in ignore-preflight-errors below).

cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay || true
modprobe br_netfilter || true

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

########################################
# containerd
########################################
log "Installing containerd"

sudo apt-get install -y containerd

mkdir -p /etc/containerd
# Always regenerate a fresh config: a stale file left behind by another
# container runtime (e.g. Docker's containerd.io, which ships with the CRI
# plugin disabled) would otherwise silently break the kubelet CRI socket.
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

########################################
# Kubernetes
########################################
log "Installing Kubernetes"

mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl


########################################
# Cluster Init
########################################
log "Initializing cluster"

kubeadm reset -f || true

# kubeadm init --pod-network-cidr=$POD_CIDR
if [ ! -f /etc/kubernetes/admin.conf ]; then
  # This host still runs cgroups v1 (Ubuntu 20.04 default). kubeadm v1.35 fails
  # preflight on cgroups v1 unless failCgroupV1 is set and the check is ignored.
  cat <<KUBEADM_CFG >/tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failCgroupV1: false
failSwapOn: false
KUBEADM_CFG

  kubeadm init --config=/tmp/kubeadm-config.yaml \
    --ignore-preflight-errors=SystemVerification,Swap \
    --skip-token-print
  # kubectl wait --for=condition=Ready node --all --timeout=300s
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config


mkdir -p /home/$SUDO_USER/.kube
cp /etc/kubernetes/admin.conf /home/$SUDO_USER/.kube/config
chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.kube

########################################
# kubectl alias
########################################
log "Adding kubectl alias"

grep -qxF "alias k=kubectl" /home/$SUDO_USER/.bashrc || \
echo "alias k=kubectl" >> /home/$SUDO_USER/.bashrc

########################################
# kubectl autocomplete (root + user)
########################################
log "Enabling kubectl autocomplete"

sudo apt-get install -y bash-completion

enable_completion() {
  TARGET_HOME=$1
  BASHRC="$TARGET_HOME/.bashrc"

  grep -qxF "source <(kubectl completion bash)" $BASHRC || \
  echo "source <(kubectl completion bash)" >> $BASHRC

  grep -qxF "alias k=kubectl" $BASHRC || \
  echo "alias k=kubectl" >> $BASHRC

  grep -qxF "complete -o default -F __start_kubectl k" $BASHRC || \
  echo "complete -o default -F __start_kubectl k" >> $BASHRC
}

# enable for original sudo user
enable_completion /home/$SUDO_USER
sudo chown $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.bashrc

# enable for root
enable_completion /root
########################################
# Network
########################################
log "Installing Flannel CNI"

kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
sleep 10
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

kubectl get nodes -o wide

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# ########################################
# # Install NGINX Ingress (bare metal)
# ########################################

# #kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
# kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml
# echo "Waiting for ingress controller..."
# kubectl wait --namespace ingress-nginx \
#   --for=condition=ready pod \
#   --selector=app.kubernetes.io/component=controller \
#   --timeout=300s

# # Force hostNetwork exposure (bare-metal behavior)
# kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json -p='[
# {"op":"add","path":"/spec/template/spec/hostNetwork","value":true},
# {"op":"add","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirstWithHostNet"}
# ]'

# kubectl rollout restart deploy ingress-nginx-controller -n ingress-nginx
########################################
# HELM
########################################
log "Installing Helm"

if ! command -v helm &>/dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

########################################
# Install NGINX Ingress (hostNetwork)
########################################
kubectl create namespace ingress-nginx 2>/dev/null || true

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.hostNetwork=true \
  --set controller.kind=DaemonSet \
  --set controller.service.enabled=false \
  --set controller.admissionWebhooks.enabled=false

kubectl rollout status daemonset ingress-nginx-controller -n ingress-nginx --timeout=300s

########################################
# Install cert-manager
########################################
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

echo "Waiting for cert-manager components..."

kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s
kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=300s

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=300s

# Extra safety delay for webhook service
sleep 10

if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
fi
########################################
# Create ClusterIssuer
########################################
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-http-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

########################################
# DEVSECOPS LANDING PORTAL
########################################

echo "======================================"
echo "Deploying DevSecOps Landing Portal"
echo "======================================"

kubectl create namespace devsecops-portal 2>/dev/null || true

########################################
# Create Landing Page HTML
########################################

cat <<EOF > /tmp/index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>DevSecOps Platform</title>

    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,
    <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'>
    <text y='.9em' font-size='90'>🚀</text>
    </svg>">

    <style>
        body {
            background: #0f172a;
            color: white;
            font-family: Arial, sans-serif;
            text-align: center;
            padding-top: 100px;
        }
        h1 {
            font-size: 40px;
            margin-bottom: 50px;
        }
        .card {
            display: inline-block;
            margin: 20px;
            padding: 30px;
            width: 220px;
            border-radius: 12px;
            background: #1e293b;
            transition: 0.3s;
        }
        .card:hover {
            background: #334155;
            transform: scale(1.05);
        }
        a {
            text-decoration: none;
            color: white;
            font-size: 20px;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <h1>🚀 DevSecOps Platform</h1>

    <div class="card">
        <a href="https://${ARGOCD_DOMAIN}" target="_blank">ArgoCD</a>
    </div>

    <div class="card">
        <a href="https://${JENKINS_DOMAIN}" target="_blank">Jenkins</a>
    </div>

    <div class="card">
        <a href="https://${TEKTON_DOMAIN}" target="_blank">Tekton</a>
    </div>

    <div class="card">
        <a href="https://${SONARQUBE_DOMAIN}" target="_blank">SonarQube</a>
    </div>

    <div class="card">
        <a href="https://${DEFECTDOJO_DOMAIN}" target="_blank">DefectDojo</a>
    </div>

</body>
</html>
EOF

########################################
# ConfigMap
########################################

kubectl create configmap portal-html \
  --from-file=index.html=/tmp/index.html \
  -n devsecops-portal \
  --dry-run=client -o yaml | kubectl apply -f -

########################################
# Deployment
########################################

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal
  namespace: devsecops-portal
spec:
  replicas: 1
  selector:
    matchLabels:
      app: portal
  template:
    metadata:
      labels:
        app: portal
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
      volumes:
      - name: html
        configMap:
          name: portal-html
EOF

########################################
# Service
########################################

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: portal
  namespace: devsecops-portal
spec:
  selector:
    app: portal
  ports:
  - port: 80
    targetPort: 80
EOF

########################################
# Ingress + TLS
########################################

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: devsecops-portal
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${ROOT_DOMAIN}
    secretName: portal-tls
  rules:
  - host: ${ROOT_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: portal
            port:
              number: 80
EOF

########################################
# Certificate Health Check + Retry Logic - ROOT
########################################

if check_cert "$ROOT_NS" "$ROOT_TLS"; then
    echo "Certificate OK, continuing..."
else
    echo "Certificate failed, but script will continue."
fi

# check_cert "$ROOT_NS" "$ROOT_TLS" || echo "Certificate failed, continuing..."

########################################
# DefectDojo
########################################
log "Installing DefectDojo"

# kubectl create namespace defectdojo 2>/dev/null || true

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo update

# kubectl create secret generic defectdojo \
#   -n defectdojo \
#   --from-literal=DD_SECRET_KEY="$(openssl rand -hex 32)" \
#   --from-literal=DD_CREDENTIAL_AES_256_KEY="$(openssl rand -hex 32)" \
#   --from-literal=METRICS_HTTP_AUTH_PASSWORD="$(openssl rand -hex 16)"

# kubectl create secret generic defectdojo-postgresql-specific \
#   -n defectdojo \
#   --from-literal=postgresql-password=StrongPostgresPass123 \
#   --from-literal=postgresql-postgres-password=StrongPostgresPass123 \
#   --dry-run=client -o yaml | kubectl apply -f -

# kubectl create secret generic defectdojo-valkey-specific \
#   -n defectdojo \
#   --from-literal=valkey-password=StrongRedisPass123 \
#   --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install defectdojo defectdojo/defectdojo \
  -n defectdojo \
  --create-namespace \
  --set createSecret=true \
  --set createValkeySecret=true \
  --set createPostgresqlSecret=true \
  --set admin.user=admin \
  --set admin.password=Admin@123 \
  --set admin.mail=admin@local \
  --set certmanager.enabled=true \
  --set django.ingress.enabled=true \
  --set django.ingress.ingressClassName=nginx \
  --set django.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-http \
  --set django.ingress.annotations."nginx\.ingress\.kubernetes\.io/force-ssl-redirect"="true" \
  --set django.ingress.annotations."nginx\.ingress\.kubernetes\.io/proxy-body-size"="50m" \
  --set host=defectdojo-${NIP_IP}.nip.io \
  --set django.ingress.hosts[0].host=defectdojo-${NIP_IP}.nip.io \
  --set django.ingress.tls[0].hosts[0]=defectdojo-${NIP_IP}.nip.io \
  --set django.ingress.tls[0].secretName=defectdojo-tls \
  --set monitoring.enabled=true \
  --set monitoring.prometheus.enabled=true \
  --set alternativeHosts={defectdojo-${NIP_IP}.nip.io} \
  --set siteUrl="https://defectdojo-${NIP_IP}.nip.io" \
  --set postgresql.primary.persistence.storageClass=local-path \
  --set valkey.primary.persistence.storageClass=local-path \
  --set django.mediaPersistentVolume.enabled=true \
  --set django.mediaPersistentVolume.persistentVolumeClaim.create=true \
  --set django.uwsgi.extraEnv[0].name=DD_SECURE_PROXY_SSL_HEADER \
  --set-string 'django.uwsgi.extraEnv[0].value=HTTP_X_FORWARDED_PROTO\,https'

########################################
# Certificate Health Check + Retry Logic - DefectDojo
########################################

check_cert "$DEFECTDOJO_NS" "$DEFECTDOJO_TLS"

########################################
# Install ArgoCD (ClusterIP)
########################################
kubectl create ns argocd 2>/dev/null || true

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --set server.service.type=ClusterIP \
  --set server.extraArgs="{--insecure}"

kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# expose argocd argocd-server 80 $ARGOCD_DOMAIN $ARGOCD_TLS

########################################
# Create Ingress for ArgoCD
########################################
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
    nginx.ingress.kubernetes.io/hsts-include-subdomains: "true"
    nginx.ingress.kubernetes.io/hsts-preload: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${ARGOCD_DOMAIN}
    secretName: argocd-tls
  rules:
  - host: ${ARGOCD_DOMAIN}
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

########################################
# Wait for Certificate
########################################
# echo "Waiting for TLS certificate..."
# kubectl wait --for=condition=Ready certificate/argocd-tls -n argocd --timeout=300s || true

########################################
# Certificate Health Check + Retry Logic - ArgoCD
########################################

check_cert "$ARGOCD_NS" "$ARGOCD_TLS"

########################################
# Jenkins
########################################
log "Installing Jenkins"

sudo apt-get install -y fontconfig openjdk-17-jdk

# remove old broken repo + keys
sudo rm -f /etc/apt/sources.list.d/jenkins.list
sudo rm -f /etc/apt/keyrings/jenkins*
sudo rm -rf /var/lib/apt/lists/*

# create keyring dir
sudo mkdir -p /etc/apt/keyrings

# install NEW official key (2026)
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

# add repo (official format)
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
 | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

# update
sudo apt update -y
sudo apt install -y jenkins
sudo systemctl enable --now jenkins
sudo systemctl start jenkins

sudo mkdir -p /root/.kube
sudo cp /etc/kubernetes/admin.conf /root/.kube/config
sudo chown root:root /root/.kube/config

########################################
# Ensure Namespace
########################################
kubectl create ns jenkins 2>/dev/null || true

########################################
# Create Service + Endpoint for external Jenkins
########################################
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
spec:
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Endpoints
metadata:
  name: jenkins
  namespace: jenkins
subsets:
  - addresses:
      - ip: ${PUBLIC_IP}
    ports:
      - port: 8080
EOF

# expose jenkins jenkins 8080 $JENKINS_DOMAIN jenkins-tls

########################################
# Create Ingress
########################################
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins
  namespace: jenkins
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${JENKINS_DOMAIN}
      secretName: jenkins-tls
  rules:
    - host: ${JENKINS_DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jenkins
                port:
                  number: 8080
EOF

########################################
# Certificate Health Check + Retry Logic - JENKINS
########################################

check_cert "$JENKINS_NS" "$JENKINS_TLS"

########################################
# SonarQube
########################################
log "Installing SonarQube"

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update

kubectl create namespace sonarqube 2>/dev/null || true

kubectl create secret generic sonarqube-monitoring-passcode \
  -n sonarqube \
  --from-literal=monitoring-passcode=demo123 \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install sonarqube sonarqube/sonarqube \
  -n sonarqube \
  --create-namespace \
  --set community.enabled=true \
  --set monitoringPasscodeSecretName=sonarqube-monitoring-passcode \
  --set monitoringPasscodeSecretKey=monitoring-passcode \
  --set ingress.enabled=true \
  --set ingress.ingressClassName=nginx \
  --set ingress.hosts[0].name=sonarqube-${NIP_IP}.nip.io \
  --set ingress.tls[0].hosts[0]=sonarqube-${NIP_IP}.nip.io \
  --set ingress.tls[0].secretName=sonarqube-tls \
  --set ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-http

########################################
# Certificate Health Check + Retry Logic - SONARQUBE
########################################
check_cert "$SONARQUBE_NS" "$SONARQUBE_TLS"

########################################
# TEKTON
########################################
log "Installing TEKTON"

########################################
# Install Tekton Pipelines
########################################
echo "[4/8] Installing Tekton Pipelines..."

kubectl create namespace $TEKTON_NS 2>/dev/null || true

kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl wait --for=condition=Established crd/pipelineruns.tekton.dev --timeout=180s
kubectl wait --for=condition=available deployment tekton-pipelines-webhook -n $TEKTON_NS --timeout=300s

########################################
# Install Tekton Dashboard
########################################
echo "[5/8] Installing Tekton Dashboard..."

kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml
kubectl wait --for=condition=available deployment tekton-dashboard -n $TEKTON_NS --timeout=300s

########################################
# Fix Dashboard RBAC
########################################
echo "[6/8] Fixing Dashboard RBAC..."

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tekton-dashboard-discovery
rules:
- nonResourceURLs:
  - "/api"
  - "/api/*"
  - "/apis"
  - "/apis/*"
  verbs: ["get"]
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-dashboard-discovery
subjects:
- kind: ServiceAccount
  name: tekton-dashboard
  namespace: $TEKTON_NS
roleRef:
  kind: ClusterRole
  name: tekton-dashboard-discovery
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl rollout restart deployment tekton-dashboard -n $TEKTON_NS

########################################
# Create HTTPS Ingress
########################################
echo "[7/8] Creating HTTPS Ingress..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-dashboard
  namespace: $TEKTON_NS
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${TEKTON_DOMAIN}
      secretName: tekton-tls
  rules:
    - host: ${TEKTON_DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tekton-dashboard
                port:
                  number: 9097
EOF

########################################
# Wait for Certificate
########################################
# echo "[8/8] Waiting for TLS certificate..."

# kubectl wait --for=condition=Ready certificate/tekton-tls \
#   -n $TEKTON_NS \
#   --timeout=300s || true

########################################
# Certificate Health Check + Retry Logic - TEKTON
########################################
check_cert "$TEKTON_NS" "$TEKTON_TLS"

#########################################
echo "[8/9] Installing Tekton CLI (tkn)..."
#########################################

ARCH=$(uname -m)

case $ARCH in
  x86_64) TKN_ARCH="x86_64" ;;
  aarch64) TKN_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

TKN_VERSION=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest | jq -r .tag_name)

FILE="tkn_${TKN_VERSION#v}_Linux_${TKN_ARCH}.tar.gz"
URL="https://github.com/tektoncd/cli/releases/download/${TKN_VERSION}/${FILE}"

echo "Downloading $URL"

wget $URL
tar -xzf $FILE
sudo mv tkn /usr/local/bin/
sudo chmod +x /usr/local/bin/tkn
rm $FILE

echo "Tekton CLI installed:"
tkn version

########################################
echo "[9/9] Validation"
########################################
sleep 10
curl -k https://${TEKTON_DOMAIN}/apis/tekton.dev/v1 >/dev/null && OK=1 || OK=0

echo ""
echo "======================================"
if [ "$OK" = "1" ]; then
  echo "TEKTON INSTALLED SUCCESSFULLY 🎉"
  echo "Open: https://${TEKTON_DOMAIN}"
else
  echo "Installed but ingress still warming up..."
fi
echo "================="
echo "Try:"
echo "tkn pipeline list"
echo ""


echo "Landing Portal deployed at:"
echo "https://${ROOT_DOMAIN}"
echo "======================================"

########################################
# Final Result
########################################

FINAL_STATUS=$(kubectl get certificate tekton-tls -n $TEKTON_NS \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$FINAL_STATUS" == "True" ]; then
    echo "🎉 Tekton TLS successfully issued!"
    echo "======================================"
    echo "✅ Tekton HTTPS Ready"
    echo "👉 https://${TEKTON_DOMAIN}"
    echo "======================================"
else
    echo "⚠ Failed after ${MAX_RETRIES} attempts."
    echo "Check:"
    echo "kubectl describe certificate tekton-tls -n $TEKTON_NS"
fi

########################################
# Final Result
########################################

FINAL_STATUS=$(kubectl get certificate $ARGOCD_TLS -n $ARGOCD_NS \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$FINAL_STATUS" != "True" ]; then
    echo "⚠ Certificate not issued after retries."
else
    echo ""
    echo "=========================================="
    echo " ArgoCD is Ready"
    echo
    echo " URL: https://${ARGOCD_DOMAIN}"
    echo
    echo -n " Username: admin"
    echo
    echo -n " Password: "
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo
    echo "=========================================="
fi

########################################
# Final Result
########################################

FINAL_STATUS=$(kubectl get certificate $JENKINS_TLS -n $JENKINS_NS \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$FINAL_STATUS" != "True" ]; then
    echo "⚠ Certificate not issued after retries."
else
    echo "===================================="
    echo " Jenkins is Ready"
    echo "https://${JENKINS_DOMAIN}"
    echo "Password:"
    cat /var/lib/jenkins/secrets/initialAdminPassword
    echo
fi

echo "Creating passwords file..."

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

JENKINS_PASS=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword)

sudo mkdir -p /etc/devsecops

sudo bash -c "cat > /etc/devsecops/passwords.json" <<EOF
{
  "ARGOCD_PASSWORD": "${ARGOCD_PASS}",
  "JENKINS_PASSWORD": "${JENKINS_PASS}"
}
EOF

sudo chmod 644 /etc/devsecops/passwords.json
