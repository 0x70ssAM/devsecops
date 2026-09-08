#!/bin/bash
# bootstrap2.sh — merged/corrected DevSecOps platform bootstrap.
#
# Combines Terraform/bootstrap.sh's completeness (real random credentials,
# GitOps ArgoCD Application/Project, Tekton Triggers, pipeline secrets,
# SonarQube/DefectDojo API token wiring, cosign key, app deployment) with
# fixes required to run this stack on a small, memory-constrained,
# cgroups-v1 host (swap prerequisite, kubelet swap tolerance, dropped
# NFS/metrics-server to save RAM, safer re-run behavior, longer timeouts
# for slow image pulls).
export KUBECONFIG=/etc/kubernetes/admin.conf
if [ "$EUID" -ne 0 ]; then
  echo "Run this script with sudo"
  exit 1
fi

set -euo pipefail

########################################
# CONFIG
########################################
EMAIL="${EMAIL:-}" # set via env var; left blank by default (no personal email hardcoded)
K8S_VERSION="v1.35"
POD_CIDR="10.244.0.0/16"
MAX_RETRIES=5
SLEEP_SECONDS=15
WAIT_TIMEOUT=600
SWAP_SIZE_GB="${SWAP_SIZE_GB:-16}"

########################################
# Secure Credentials (random unless overridden via env)
########################################
DEFECTDOJO_ADMIN_PASS="${DEFECTDOJO_ADMIN_PASS:-$(openssl rand -base64 18)}"
SONARQUBE_MON_PASS="${SONARQUBE_MON_PASS:-$(openssl rand -base64 18)}"
SONARQUBE_ADMIN_PASS="${SONARQUBE_ADMIN_PASS:-$(openssl rand -base64 18)}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

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
    echo "Checking certificate: $CERT (namespace: $NS)"
    echo "Max retries: $MAX_RETRIES"

    while [ "$retry" -lt "$MAX_RETRIES" ]; do
        STATUS=$(kubectl get certificate "$CERT" -n "$NS" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

        if [ "$STATUS" == "True" ]; then
            echo "Certificate $CERT is Ready!"
            return 0
        fi

        echo "Not Ready (Attempt $((retry+1))/$MAX_RETRIES)"
        sleep 5
        kubectl delete certificate "$CERT" -n "$NS" --ignore-not-found
        kubectl delete secret "$CERT" -n "$NS" --ignore-not-found
        sleep "$SLEEP_SECONDS"
        retry=$((retry+1))
    done

    echo "Certificate $CERT failed after $MAX_RETRIES retries"
    return 1
}

########################################
# Variables
########################################
PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://api.ipify.org)
NIP_IP=$(echo $PUBLIC_IP | tr '.' '-')

ROOT_DOMAIN="${ROOT_DOMAIN:-}"   # optional fixed domain (e.g. an Azure custom domain you own); leave empty to skip
ROOT_TLS="portal-tls"
ROOT_NS="devsecops-portal"

ARGOCD_DOMAIN="argocd-${NIP_IP}.nip.io"
ARGOCD_URL="argocd-${NIP_IP}.nip.io"
ARGOCD_TLS="argocd-tls"
ARGOCD_NS="argocd"

JENKINS_DOMAIN="jenkins-${NIP_IP}.nip.io"
JENKINS_URL="jenkins-${NIP_IP}.nip.io"
JENKINS_TLS="jenkins-tls"
JENKINS_NS="jenkins"

TEKTON_DOMAIN="tekton-${NIP_IP}.nip.io"
TEKTON_URL="tekton-${NIP_IP}.nip.io"
TEKTON_TLS="tekton-tls"
TEKTON_NS="tekton-pipelines"

SONARQUBE_DOMAIN="sonarqube-${NIP_IP}.nip.io"
SONAR_URL="sonarqube-${NIP_IP}.nip.io"
SONARQUBE_TLS="sonarqube-tls"
SONARQUBE_NS="sonarqube"

DEFECTDOJO_DOMAIN="defectdojo-${NIP_IP}.nip.io"
DEFECTDOJO_URL="defectdojo-${NIP_IP}.nip.io"
DEFECTDOJO_TLS="defectdojo-tls"
DEFECTDOJO_NS="defectdojo"

APP_DOMAIN="devsecops-${NIP_IP}.nip.io"
APP_URL="devsecops-${NIP_IP}.nip.io"
APP_TLS="app-tls"
APP_NS="dev"

echo "Public IP: $PUBLIC_IP"

########################################
# SWAP PREREQUISITE
########################################
# This platform was sized for 32GB RAM (see Terraform/main.tf,
# Standard_E4ds_v4). On a smaller host, swap is the only practical
# mitigation against OOM kills for the JVM-heavy services (Jenkins,
# SonarQube) and DefectDojo's Django/Celery/Postgres stack. Swap is
# intentionally kept ON through kubeadm init (see failSwapOn below) —
# do NOT swapoff here.
TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
if [ "$TOTAL_MEM_GB" -lt 16 ]; then
  log "Host has ${TOTAL_MEM_GB}GB RAM (platform is sized for 32GB) — provisioning ${SWAP_SIZE_GB}GB swap as headroom"
  if swapon --show | grep -q "/swapfile"; then
    echo "swapfile already active, skipping creation"
  else
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -qxF "/swapfile none swap sw 0 0" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
  sysctl -w vm.swappiness=10
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swap-tuning.conf
else
  log "Host has ${TOTAL_MEM_GB}GB RAM — swap prerequisite skipped"
fi

# Required by SonarQube's embedded Elasticsearch
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-sonarqube.conf

########################################
# SYSTEM PREP
########################################
log "Installing base packages"

apt-get update -y
apt-get install -y sshpass curl wget git jq ca-certificates gnupg gnupg-agent dirmngr lsb-release software-properties-common apt-transport-https bash-completion

########################################
# Build Tools
########################################
log "Installing Build Tools"

apt-get install -y openjdk-17-jdk openjdk-21-jdk
apt-get install -y maven
apt-get install -y gradle

curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

apt-get install -y python3 python3-pip python3-venv pipx

echo "Java version:"; java -version
echo "Maven version:"; mvn -version
echo "Gradle version:"; gradle -v
echo "Node version:"; node -v
echo "Python version:"; python3 --version

########################################
# Kernel modules / sysctl for Kubernetes networking
# NOTE: no swapoff here — see SWAP PREREQUISITE above.
########################################
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

apt-get install -y containerd

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

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

########################################
# Cluster Init
########################################
log "Initializing cluster"

# Only reset/init if there is no existing cluster on this host. The
# original lab script ran `kubeadm reset -f` unconditionally, which
# destroys an already-running cluster (etcd data, PKI, admin.conf) every
# time the script is re-run — making recovery from a mid-script failure
# needlessly destructive. Guard it instead.
if [ ! -f /etc/kubernetes/admin.conf ]; then
  kubeadm reset -f || true

  # This host may run cgroups v1 (Ubuntu 20.04 default). kubeadm v1.35 fails
  # preflight on cgroups v1 unless failCgroupV1 is set and the check is
  # ignored. Swap is also kept on (see SWAP PREREQUISITE), so kubelet is
  # told to tolerate it via failSwapOn — swap support for NodeSwap is
  # cgroup-v2-only, so this is a soft/no-limit-enforcement swap, not full
  # NodeSwap accounting; it still helps as general OS-level headroom.
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
  export KUBECONFIG=/etc/kubernetes/admin.conf
else
  log "Existing cluster detected at /etc/kubernetes/admin.conf — skipping kubeadm reset/init"
fi

mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config

mkdir -p /home/$SUDO_USER/.kube
cp /etc/kubernetes/admin.conf /home/$SUDO_USER/.kube/config
chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.kube

########################################
# kubectl alias + autocomplete (root + user)
########################################
log "Adding kubectl alias and autocomplete"

apt-get install -y bash-completion

enable_completion() {
  TARGET_HOME=$1
  BASHRC="$TARGET_HOME/.bashrc"

  grep -qxF "alias k=kubectl" $BASHRC || echo "alias k=kubectl" >> $BASHRC
  grep -qxF "source <(kubectl completion bash)" $BASHRC || echo "source <(kubectl completion bash)" >> $BASHRC
  grep -qxF "complete -o default -F __start_kubectl k" $BASHRC || echo "complete -o default -F __start_kubectl k" >> $BASHRC
}

enable_completion /home/$SUDO_USER
chown $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.bashrc
enable_completion /root

########################################
# Network (Flannel + local-path storage)
# NOTE: NFS server + nfs-subdir-external-provisioner intentionally
# dropped versus bootstrap.sh — extra RWX storage isn't needed for a
# single-node lab and costs memory we don't have to spare here.
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

########################################
# devsecops configmap (consumed by Tekton pipelines)
########################################
kubectl create namespace tekton-devsecops 2>/dev/null || true

kubectl create configmap devsecops-urls \
  --namespace tekton-devsecops \
  --from-literal=SONAR_URL=https://$SONAR_URL \
  --from-literal=DEFECTDOJO_URL=https://$DEFECTDOJO_URL \
  --from-literal=JENKINS_URL=https://$JENKINS_URL \
  --from-literal=ARGOCD_URL=https://$ARGOCD_URL \
  --from-literal=ARGOCD_SERVER=$ARGOCD_URL \
  --from-literal=TEKTON_URL=https://$TEKTON_URL \
  --from-literal=APP_URL=https://$APP_URL \
  --dry-run=client -o yaml | kubectl apply -f -

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
# NOTE: timeouts bumped from 300s to 600s — on this host's network,
# ghcr.io/registry.k8s.io pulls have been observed to exceed 300s.
########################################
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

echo "Waiting for cert-manager components..."
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=600s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=600s
kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=600s

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=300s

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
        body { background: #0f172a; color: white; font-family: Arial, sans-serif; text-align: center; padding-top: 100px; }
        h1 { font-size: 40px; margin-bottom: 50px; }
        .card { display: inline-block; margin: 20px; padding: 30px; width: 220px; border-radius: 12px; background: #1e293b; transition: 0.3s; }
        .card:hover { background: #334155; transform: scale(1.05); }
        a { text-decoration: none; color: white; font-size: 20px; font-weight: bold; }
    </style>
</head>
<body>
    <h1>🚀 DevSecOps Platform</h1>
    <div class="card"><a href="https://${ARGOCD_DOMAIN}" target="_blank">ArgoCD</a></div>
    <div class="card"><a href="https://${JENKINS_DOMAIN}" target="_blank">Jenkins</a></div>
    <div class="card"><a href="https://${TEKTON_DOMAIN}" target="_blank">Tekton</a></div>
    <div class="card"><a href="https://${SONARQUBE_DOMAIN}" target="_blank">SonarQube</a></div>
    <div class="card"><a href="https://${DEFECTDOJO_DOMAIN}" target="_blank">DefectDojo</a></div>
    <div class="card"><a href="https://${APP_DOMAIN}" target="_blank">App</a></div>
</body>
</html>
EOF

kubectl create configmap portal-html \
  --from-file=index.html=/tmp/index.html \
  -n devsecops-portal \
  --dry-run=client -o yaml | kubectl apply -f -

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

if [ -n "$ROOT_DOMAIN" ]; then
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

  if check_cert "$ROOT_NS" "$ROOT_TLS"; then
      echo "Certificate OK, continuing..."
  else
      echo "Certificate failed, but script will continue."
  fi
else
  warn "ROOT_DOMAIN not set — skipping the fixed-domain landing portal ingress/cert (nip.io domains for each tool still work)."
fi

########################################
# DefectDojo
########################################
log "Installing DefectDojo"

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo update

helm upgrade --install defectdojo defectdojo/defectdojo \
  -n defectdojo \
  --create-namespace \
  --set createSecret=true \
  --set createValkeySecret=true \
  --set createPostgresqlSecret=true \
  --set admin.user=admin \
  --set admin.password="$DEFECTDOJO_ADMIN_PASS" \
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
  --set django.uwsgi.resources.requests.memory=1Gi \
  --set django.uwsgi.resources.limits.memory=2Gi \
  --set django.uwsgi.extraEnv[0].name=DD_SECURE_PROXY_SSL_HEADER \
  --set-string 'django.uwsgi.extraEnv[0].value=HTTP_X_FORWARDED_PROTO\,https'

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

kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=600s

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

check_cert "$ARGOCD_NS" "$ARGOCD_TLS"

########################################
# ArgoCD GitOps — Project + Application
########################################
log "Configuring ArgoCD GitOps deployment"

kubectl create namespace dev 2>/dev/null || true

cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: devsecops-project
  namespace: argocd
spec:
  description: "DevSecOps platform project"
  sourceRepos:
  - "https://github.com/0x70ssAM/devsecops"
  - "https://github.com/0x70ssAM/devsecops.git"
  destinations:
  - namespace: dev
    server: https://kubernetes.default.svc
  - namespace: default
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
EOF

echo "ArgoCD Project 'devsecops-project' created"

cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devsecops-app
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: devsecops
spec:
  project: devsecops-project
  source:
    repoURL: https://github.com/0x70ssAM/devsecops
    targetRevision: main
    path: .
    directory:
      include: "k8s_deployment_service.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - ApplyOutOfSyncOnly=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 60s
EOF

echo "ArgoCD Application 'devsecops-app' created"

########################################
# Git Credentials for Tekton GitOps Push
########################################
GIT_USERNAME="${GIT_USERNAME:-tekton-bot}"
GIT_TOKEN="${GIT_TOKEN:-}"

if [ -n "$GIT_TOKEN" ]; then
  log "Creating git-credentials secret for Tekton"
  kubectl create secret generic git-credentials \
    --from-literal=username="$GIT_USERNAME" \
    --from-literal=token="$GIT_TOKEN" \
    -n tekton-devsecops \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "git-credentials secret created"
else
  warn "GIT_TOKEN not set — Tekton GitOps push will not work until git-credentials secret is created manually:"
  warn "  kubectl create secret generic git-credentials --from-literal=username=YOUR_USER --from-literal=token=YOUR_GITHUB_PAT -n tekton-devsecops"
fi

########################################
# DockerHub Credentials for Kaniko Push
########################################
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"

if [ -n "$DOCKERHUB_TOKEN" ] && [ -n "$DOCKERHUB_USERNAME" ]; then
  log "Creating dockerhub-secret for Kaniko"
  kubectl create secret docker-registry dockerhub-secret \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKERHUB_USERNAME" \
    --docker-password="$DOCKERHUB_TOKEN" \
    --docker-email=dummy@example.com \
    -n tekton-devsecops \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "dockerhub-secret created"
else
  warn "DOCKERHUB_TOKEN or DOCKERHUB_USERNAME not set — Kaniko push will not work until dockerhub-secret is created manually:"
  warn "  kubectl create secret docker-registry dockerhub-secret --docker-server=https://index.docker.io/v1/ --docker-username=YOUR_DOCKERHUB_USER --docker-password=YOUR_DOCKERHUB_TOKEN --docker-email=dummy@example.com -n tekton-devsecops"
fi

########################################
# SonarQube
########################################
log "Installing SonarQube"

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update

kubectl create namespace sonarqube 2>/dev/null || true

kubectl create secret generic sonarqube-monitoring-passcode \
  -n sonarqube \
  --from-literal=monitoring-passcode="$SONARQUBE_MON_PASS" \
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

check_cert "$SONARQUBE_NS" "$SONARQUBE_TLS"

########################################
# Jenkins
########################################
log "Installing Jenkins"

apt-get install -y fontconfig openjdk-17-jdk

rm -f /etc/apt/sources.list.d/jenkins.list
rm -f /etc/apt/keyrings/jenkins*
rm -rf /var/lib/apt/lists/*

mkdir -p /etc/apt/keyrings

wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
 | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt-get update -y
apt-get install -y jenkins
systemctl enable --now jenkins
systemctl start jenkins

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

kubectl create ns jenkins 2>/dev/null || true

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
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    kubernetes.io/service-name: jenkins
addressType: IPv4
ports:
  - name: ""
    port: 8080
endpoints:
  - addresses:
      - ${PUBLIC_IP}
EOF

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

check_cert "$JENKINS_NS" "$JENKINS_TLS"

########################################
# TEKTON
########################################
log "Installing TEKTON"

echo "[1/5] Installing Tekton Pipelines..."
kubectl create namespace $TEKTON_NS 2>/dev/null || true

kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl wait --for=condition=Established crd/pipelineruns.tekton.dev --timeout=180s
kubectl wait --for=condition=available deployment tekton-pipelines-webhook -n $TEKTON_NS --timeout=600s

echo "[2/5] Installing Tekton Dashboard..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml
kubectl wait --for=condition=available deployment tekton-dashboard -n $TEKTON_NS --timeout=600s

kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

echo "[3/5] Fixing Dashboard RBAC..."
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
kubectl rollout status deployment tekton-dashboard -n $TEKTON_NS --timeout=300s

echo "[4/5] Creating HTTPS Ingress..."
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

check_cert "$TEKTON_NS" "$TEKTON_TLS"

echo "[5/5] Installing Tekton CLI (tkn)..."
ARCH=$(uname -m)
case $ARCH in
  x86_64) TKN_ARCH="x86_64" ;;
  aarch64) TKN_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if ! command -v tkn &>/dev/null; then
  TKN_VERSION=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest | jq -r .tag_name)
  FILE="tkn_${TKN_VERSION#v}_Linux_${TKN_ARCH}.tar.gz"
  URL="https://github.com/tektoncd/cli/releases/download/${TKN_VERSION}/${FILE}"
  echo "Downloading $URL"
  (cd /tmp && wget -q "$URL" && tar -xzf "$FILE" && mv tkn /usr/local/bin/ && chmod +x /usr/local/bin/tkn && rm -f "$FILE")
fi

echo "Tekton CLI installed:"
tkn version

echo "Validation..."
sleep 10
curl -k https://${TEKTON_DOMAIN}/apis/tekton.dev/v1 >/dev/null && OK=1 || OK=0
if [ "$OK" = "1" ]; then
  echo "TEKTON INSTALLED SUCCESSFULLY"
  echo "Open: https://${TEKTON_DOMAIN}"
else
  echo "Installed but ingress still warming up..."
fi

# Disable Tekton Affinity Assistant so PipelineRuns can use multiple PVC
# workspaces (required when pipelines mount more than one volume)
kubectl patch configmap feature-flags -n tekton-pipelines \
  --type merge -p '{"data":{"coschedule":"disabled"}}'
kubectl rollout restart deployment tekton-pipelines-controller -n tekton-pipelines

echo "Landing Portal card links point at: ${ARGOCD_DOMAIN}, ${JENKINS_DOMAIN}, ${TEKTON_DOMAIN}, ${SONARQUBE_DOMAIN}, ${DEFECTDOJO_DOMAIN}, ${APP_DOMAIN}"

########################################
# Passwords file
########################################
echo "Creating passwords file..."

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

kubectl create secret generic argo-pass \
  --from-literal=password="$ARGOCD_PASS" \
  -n tekton-devsecops \
  --dry-run=client -o yaml | kubectl apply -f -

JENKINS_PASS=$(cat /var/lib/jenkins/secrets/initialAdminPassword)

mkdir -p /etc/devsecops

bash -c "cat > /etc/devsecops/passwords.json" <<EOF
{
  "ARGOCD_PASSWORD": "${ARGOCD_PASS}",
  "JENKINS_PASSWORD": "${JENKINS_PASS}",
  "DEFECTDOJO_PASSWORD": "${DEFECTDOJO_ADMIN_PASS}",
  "SONARQUBE_PASSWORD": "${SONARQUBE_ADMIN_PASS}"
}
EOF

chown "${SUDO_USER:-root}:${SUDO_USER:-root}" /etc/devsecops/passwords.json
chmod 600 /etc/devsecops/passwords.json

########################################
# Wait for SonarQube, rotate default password, generate API token
########################################
echo "Waiting for SonarQube..."

SONA_ELAPSED=0
until curl -sk "https://$SONAR_URL/api/system/status" | grep -q '"status":"UP"'; do
  sleep 5
  SONA_ELAPSED=$((SONA_ELAPSED + 5))
  if [ "$SONA_ELAPSED" -ge "$WAIT_TIMEOUT" ]; then
    warn "SonarQube did not become ready within ${WAIT_TIMEOUT}s"
    break
  fi
done
echo "SonarQube ready"

curl -sk -L -u "admin:admin" -X POST \
  --data-urlencode "login=admin" \
  --data-urlencode "previousPassword=admin" \
  --data-urlencode "password=$SONARQUBE_ADMIN_PASS" \
  "https://$SONAR_URL/api/users/change_password" || true

SONAR_TOKEN=$(curl -sk -L -u "admin:$SONARQUBE_ADMIN_PASS" -X POST --data-urlencode "name=tekton-token1" "https://$SONAR_URL/api/user_tokens/generate" | jq -r '.token')

kubectl create secret generic sonar-secret \
  --from-literal=token="$SONAR_TOKEN" \
  -n tekton-devsecops \
  --dry-run=client -o yaml | kubectl apply -f -

########################################
# Wait for DefectDojo, generate API token
########################################
DD_URL="https://${DEFECTDOJO_URL}"
DD_USER="admin"
DD_PASS="$DEFECTDOJO_ADMIN_PASS"

echo "Waiting for DefectDojo..."

DD_ELAPSED=0
until [ "$(curl -sk -o /dev/null -w "%{http_code}" "$DD_URL/api/v2/oa3/schema/?format=json")" = "200" ]; do
  sleep 5
  DD_ELAPSED=$((DD_ELAPSED + 5))
  if [ "$DD_ELAPSED" -ge "$WAIT_TIMEOUT" ]; then
    warn "DefectDojo did not become ready within ${WAIT_TIMEOUT}s"
    break
  fi
done
echo "DefectDojo ready"

DD_TOKEN=$(curl -sk -X POST \
  -H "content-type: application/json" \
  "$DD_URL/api/v2/api-token-auth/" \
  -d "{\"username\":\"$DD_USER\",\"password\":\"$DD_PASS\"}" \
  | jq -r '.token')

kubectl create secret generic defectdojo-secret \
  --from-literal=token="$DD_TOKEN" \
  -n tekton-devsecops \
  --dry-run=client -o yaml | kubectl apply -f -

########################################
# Slack Webhook Secret
########################################
if [ -n "$SLACK_WEBHOOK_URL" ]; then
  log "Creating Slack webhook secret"
  kubectl create secret generic slack-webhook-secret \
    --from-literal=url="$SLACK_WEBHOOK_URL" \
    -n tekton-devsecops \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Slack webhook secret created"
else
  warn "SLACK_WEBHOOK_URL not set — Slack notifications will be local-only"
fi

########################################
# Cosign Signing Key
########################################
log "Generating Cosign signing key for image signing"

if ! command -v cosign &>/dev/null; then
  COSIGN_VERSION="v2.4.1"
  curl -sL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" -o /usr/local/bin/cosign
  chmod +x /usr/local/bin/cosign
fi

COSIGN_DIR=$(mktemp -d)
COSIGN_PASSWORD=$(openssl rand -hex 16)

pushd "$COSIGN_DIR" > /dev/null
COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign generate-key-pair 2>/dev/null || true
popd > /dev/null

if [ -f "$COSIGN_DIR/cosign.key" ]; then
  kubectl create secret generic cosign-key \
    --from-file=cosign.key="$COSIGN_DIR/cosign.key" \
    --from-file=cosign.pub="$COSIGN_DIR/cosign.pub" \
    --from-literal=password="$COSIGN_PASSWORD" \
    -n tekton-devsecops \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Cosign signing key created"
  rm -rf "$COSIGN_DIR"
else
  warn "Cosign key generation failed — image signing will be unavailable"
fi

########################################
# Application Ingress
########################################
log "Deploying Application Ingress"

kubectl create namespace "$APP_NS" 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: devsecops-ingress
  namespace: $APP_NS
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${APP_DOMAIN}
    secretName: ${APP_TLS}
  rules:
  - host: ${APP_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: devsecops
            port:
              number: 8080
EOF

check_cert "$APP_NS" "$APP_TLS" || warn "App cert not ready yet — fine until the app Deployment/Service actually exist (ArgoCD will create them once it syncs devsecops-app)."

echo ""
echo "=========================================="
echo " DevSecOps platform bootstrap complete"
echo "=========================================="
echo " ArgoCD:     https://${ARGOCD_URL}  (admin / see /etc/devsecops/passwords.json)"
echo " Jenkins:    https://${JENKINS_URL} (admin / see /etc/devsecops/passwords.json)"
echo " SonarQube:  https://${SONAR_URL}   (admin / see /etc/devsecops/passwords.json)"
echo " DefectDojo: https://${DEFECTDOJO_URL} (admin / see /etc/devsecops/passwords.json)"
echo " Tekton:     https://${TEKTON_URL}"
echo " App:        https://${APP_URL} (once ArgoCD syncs devsecops-app)"
echo "=========================================="
echo "Bootstrap completed successfully"
