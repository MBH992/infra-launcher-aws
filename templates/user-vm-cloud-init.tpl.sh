#!/bin/bash
set -eux

# Update and upgrade packages (force IPv4 to avoid apt IPv6 stalls)
apt-get -o Acquire::ForceIPv4=true update || apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true upgrade -y || true

# Hostname/hosts 설정
hostnamectl set-hostname control-plane
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
if ! grep -q "control-plane" /etc/hosts; then
  echo "${PRIVATE_IP} control-plane" >> /etc/hosts
fi

# 실습 홈 디렉토리 준비
LEARN_HOME="/home/learn-k8s"
mkdir -p "${LEARN_HOME}"
chown ubuntu:ubuntu "${LEARN_HOME}"
if ! grep -q "cd ${LEARN_HOME}" /home/ubuntu/.bashrc; then
  echo "cd ${LEARN_HOME}" >> /home/ubuntu/.bashrc
fi

# Install base dependencies for Kubernetes tooling / terminal stack
apt-get -o Acquire::ForceIPv4=true install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  conntrack \
  socat \
  ebtables \
  ethtool \
  git \
  build-essential

# Disable swap for k3s and ensure it stays off
swapoff -a
sed -i.bak '/swap/d' /etc/fstab

# Install single-node k3s cluster (bundles kubectl via /usr/local/bin/kubectl)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -s -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
chmod 644 "$KUBECONFIG"
chown ubuntu:ubuntu "$KUBECONFIG"
cat <<'EOF' > /etc/profile.d/k3s.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get -o Acquire::ForceIPv4=true install -y nodejs

# Install PM2 globally
npm install -g pm2

# Clone or update terminal backend code
APP_SRC="/opt/terminal-server"
APP_DIR="/usr/local/lib/terminal-server"
rm -rf "${APP_SRC}" "${APP_DIR}"
mkdir -p /opt
git clone https://github.com/getsoss/learn-kubernetes-vm "${APP_SRC}"
cd "${APP_SRC}"
npm install
mkdir -p "$(dirname "${APP_DIR}")"
mv "${APP_SRC}" "${APP_DIR}"
cd "${APP_DIR}"

# 실습용 YAML 배치
cat <<'EOF' > "${LEARN_HOME}/nginx.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.14.2
    ports:
    - containerPort: 80
EOF

cat <<'EOF' > "${LEARN_HOME}/nginx-error.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: nginx-error
spec:
  containers:
  - name: nginx
    image: nginx:error
    ports:
    - containerPort: 80
EOF

cat <<'EOF' > "${LEARN_HOME}/busybox.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: busybox
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sh", "-c", "echo Booting busybox && exit 1"]
  restartPolicy: Always
EOF

chown ubuntu:ubuntu "${LEARN_HOME}/"*.yaml

# 문제 상태 미리 구성
for i in {1..10}; do
  if kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
kubectl apply -f "${LEARN_HOME}/busybox.yaml"
kubectl apply -f "${LEARN_HOME}/nginx-error.yaml"

# Start websocket server through PM2
export HOME="${LEARN_HOME}"
export PM2_HOME="/root/.pm2"
pm2 delete websocket-server >/dev/null 2>&1 || true
pm2 delete k8s-api-server >/dev/null 2>&1 || true
pm2 start node --name websocket-server -- "${APP_DIR}/websocket-server.js"
export K8S_API_PORT=8890
pm2 start node --name k8s-api-server -- "${APP_DIR}/k8s-api-server.js"
pm2 save
pm2 startup systemd -u root --hp /root

# Register session with proxy
curl -X POST http://{{PROXY_IP}}:8080/register-session \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "{{SESSION_ID}}", "vmIp": "'$(hostname -I | awk '{print $1}')'"}'

# 원본 코드 제거
rm -rf /opt/terminal-server
