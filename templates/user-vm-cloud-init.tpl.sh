#!/bin/bash
set -eux

# Update and upgrade packages (force IPv4 to avoid apt IPv6 stalls)
apt-get -o Acquire::ForceIPv4=true update || apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true upgrade -y || true

# Install base dependencies for Kubernetes tooling
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
  build-essential \
  docker.io

# Enable and start Docker for Minikube
systemctl enable docker
systemctl start docker

# Install kubectl
KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
curl -L --fail -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# Install Minikube
curl -L --fail -o /tmp/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
install /tmp/minikube /usr/local/bin/minikube
rm /tmp/minikube

# Start Minikube cluster
minikube start --driver=docker --wait=all

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get -o Acquire::ForceIPv4=true install -y nodejs

# Install PM2 globally
npm install -g pm2

# Clone terminal backend code
mkdir -p /opt/terminal-server
cd /opt/terminal-server
git clone https://github.com/getsoss/learn-kubernetes .

cat <<'ENV' > /opt/terminal-server/.env.local
NEXT_PUBLIC_WEBSOCKET_URL=ws://{{PROXY_IP}}:8080/session/{{SESSION_ID}}
ENV

npm install
npm run build

# Start Next.js (all interfaces) and websocket server through PM2
pm2 start npm --name next-app -- run start -- --hostname 0.0.0.0 --port 3000
pm2 start websocket-server.js --name websocket-server
pm2 save
pm2 startup systemd -u root --hp /root

# Register session with proxy
curl -X POST http://{{PROXY_IP}}:8080/register-session \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "{{SESSION_ID}}", "vmIp": "'$(hostname -I | awk '{print $1}')"'}'
