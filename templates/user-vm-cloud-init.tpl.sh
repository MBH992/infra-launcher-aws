#!/bin/bash
set -eux


# Update and upgrade packages (force IPv4 to avoid apt IPv6 stalls)
apt-get -o Acquire::ForceIPv4=true update || apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true upgrade -y || true

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

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get -o Acquire::ForceIPv4=true install -y nodejs

# Install PM2 globally
npm install -g pm2

# Clone or update terminal backend code
mkdir -p /opt/terminal-server
cd /opt/terminal-server
git clone https://github.com/getsoss/learn-kubernetes .

npm install

# Start websocket server through PM2
pm2 delete websocket-server >/dev/null 2>&1 || true
pm2 start node --name websocket-server -- websocket-server.js
pm2 start node --name k8s-api-server -- k8s-api-server.js
pm2 save
pm2 startup systemd -u root --hp /root

# Register session with proxy
curl -X POST http://{{PROXY_IP}}:8080/register-session \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "{{SESSION_ID}}", "vmIp": "'$(hostname -I | awk '{print $1}')'"}'
