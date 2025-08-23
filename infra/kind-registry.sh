#!/bin/bash
set -euo pipefail

# ==============================
# Config
# ==============================
CLUSTER_NAME="kind-cluster"
REG_NAME="kind-registry"
REG_PORT="5000"
APP_IMAGE_NAME="springboot-cicd-eks"
APP_LOCAL_IMAGE="localhost:${REG_PORT}/${APP_IMAGE_NAME}:latest"
NAMESPACE="team-app"
TLS_DIR="./tls"
TLS_CERT="${TLS_DIR}/tls.crt"
TLS_KEY="${TLS_DIR}/tls.key"
HOST_ENTRY="spring.local"

# ==============================
# Helper checks
# ==============================
for cmd in docker kind kubectl openssl; do
  if ! command -v $cmd &>/dev/null; then
    echo "❌ $cmd is not installed."
    exit 1
  fi
done

# ==============================
# Cleanup
# ==============================
cleanup() {
  kind delete cluster --name "${CLUSTER_NAME}" || true
  docker rm -f "${REG_NAME}" 2>/dev/null || true
  sed -i.bak "/${HOST_ENTRY}/d" /etc/hosts 2>/dev/null || true
  echo "🧹 Cleanup complete."
}

# ==============================
# Ensure registry
# ==============================
ensure_registry() {
  if [ "$(docker ps -q -f name=${REG_NAME})" ]; then
    echo "✅ Registry already running."
  else
    echo "👉 Starting local registry..."
    docker run -d --restart=always -p "${REG_PORT}:5000" --name "${REG_NAME}" registry:2
  fi
}

# ==============================
# Ensure cluster
# ==============================
ensure_cluster() {
  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "✅ Kind cluster exists."
  else
    echo "👉 Creating Kind cluster..."
    kind create cluster --name "${CLUSTER_NAME}" --config kind-cluster.yaml
  fi

  docker network connect "kind" "${REG_NAME}" 2>/dev/null || true

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

# ==============================
# Build + Push app image
# ==============================
build_app_image() {
  echo "👉 Building application image..."
  if command -v mvn >/dev/null && [ -f pom.xml ]; then
    echo "⚡ Building with Maven Jib (cache aware)..."
    if mvn compile jib:dockerBuild -Dimage="${APP_IMAGE_NAME}:latest"; then
      :
    else
      echo "⚠️ Jib build failed. Falling back to Dockerfile build..."
      docker build --build-arg BUILDKIT_INLINE_CACHE=1 -t "${APP_IMAGE_NAME}:latest" .
    fi
  elif [ -f Dockerfile ]; then
    echo "⚡ Building with Dockerfile (cache aware)..."
    docker build --build-arg BUILDKIT_INLINE_CACHE=1 -t "${APP_IMAGE_NAME}:latest" .
  else
    echo "❌ No build definition (pom.xml or Dockerfile) found."
    exit 1
  fi

  docker tag "${APP_IMAGE_NAME}:latest" "${APP_LOCAL_IMAGE}"
  docker push "${APP_LOCAL_IMAGE}"
  echo "✅ Application image pushed to local registry."
}

# ==============================
# TLS management
# ==============================
ensure_tls() {
  mkdir -p "${TLS_DIR}"

  if [ -f "${TLS_CERT}" ] && [ -f "${TLS_KEY}" ]; then
    end_date=$(openssl x509 -enddate -noout -in "${TLS_CERT}" | cut -d= -f2)
    end_epoch=$(date -d "$end_date" +%s)
    now_epoch=$(date +%s)
    days_left=$(( (end_epoch - now_epoch) / 86400 ))

    if [ $days_left -gt 30 ]; then
      echo "✅ TLS cert valid for ${days_left} more days."
    else
      echo "⚠️ TLS cert expires in ${days_left} days. Regenerating..."
      rm -f "${TLS_CERT}" "${TLS_KEY}"
    fi
  fi

  if [ ! -f "${TLS_CERT}" ] || [ ! -f "${TLS_KEY}" ]; then
    echo "👉 Generating new self-signed TLS cert..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${TLS_KEY}" -out "${TLS_CERT}" \
      -subj "/CN=${HOST_ENTRY}/O=${HOST_ENTRY}"
    echo "✅ New TLS cert created (365 days)."
  fi

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret tls springboot-tls \
    --cert="${TLS_CERT}" \
    --key="${TLS_KEY}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "🔑 Kubernetes TLS secret 'springboot-tls' updated."
}

# ==============================
# Ensure ingress controller
# ==============================
ensure_ingress() {
  if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    echo "✅ Ingress controller already installed."
  else
    echo "👉 Installing NGINX Ingress Controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    kubectl wait --namespace ingress-nginx \
      --for=condition=Available deployment/ingress-nginx-controller \
      --timeout=180s
  fi
}

# ==============================
# Deploy app
# ==============================
deploy_app() {
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: springboot-app
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: springboot-app
  template:
    metadata:
      labels:
        app: springboot-app
    spec:
      containers:
      - name: springboot-app
        image: ${APP_LOCAL_IMAGE}
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: springboot-cicd-eks-config
        - secretRef:
            name: springboot-cicd-eks-secret
        readinessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: springboot-service
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: springboot-app
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: springboot-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${HOST_ENTRY}
    secretName: springboot-tls
  rules:
  - host: ${HOST_ENTRY}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: springboot-service
            port:
              number: 8080
EOF
  echo "✅ Spring Boot app deployed with TLS Ingress."
}

# ==============================
# /etc/hosts patch
# ==============================
patch_hosts() {
  if ! grep -q "${HOST_ENTRY}" /etc/hosts; then
    echo "👉 Patching /etc/hosts (requires sudo)..."
    echo "127.0.0.1 ${HOST_ENTRY}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

# ==============================
# Main workflow
# ==============================
main() {
  ensure_registry
  ensure_cluster
  build_app_image
  ensure_tls
  ensure_ingress
  deploy_app
  patch_hosts
  echo "🌐 Access app via: https://${HOST_ENTRY}"
}

# ==============================
# Entry point
# ==============================
case "${1:-}" in
  cleanup) cleanup ;;
  reset) cleanup && main ;;
  renew-tls) ensure_tls ;;
  *) main ;;
esac
