#!/bin/bash
set -e

CLUSTER_NAME="kind-cluster"
REG_NAME="kind-registry"
REG_PORT="5000"

echo "👉 Starting local Docker registry on port ${REG_PORT}..."
# Run local registry if not already running
running="$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)"
if [ "${running}" != "true" ]; then
  docker run -d --restart=always -p "${REG_PORT}:5000" --name "${REG_NAME}" registry:2
fi

echo "👉 Creating Kind cluster (${CLUSTER_NAME})..."
kind create cluster --name "${CLUSTER_NAME}" --config kind-cluster.yaml || true

echo "👉 Connecting registry container to kind network..."
docker network connect "kind" "${REG_NAME}" || true

echo "👉 Applying local registry ConfigMap..."
cat <<EOF | kubectl apply -f -
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

echo "✅ Kind cluster with local registry is ready!"
