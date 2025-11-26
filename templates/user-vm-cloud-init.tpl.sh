#!/bin/bash
set -eux

retry() {
  local attempts=$1
  shift
  local count=0
  until "$@"; do
    count=$((count + 1))
    if [ "$count" -ge "$attempts" ]; then
      echo "Command failed after ${attempts} attempts: $*" >&2
      return 1
    fi
    echo "Retrying ($count/${attempts}): $*" >&2
    sleep 5
  done
}

wait_for_pm2() {
  local name=$1
  local attempts=${2:-10}
  for i in $(seq 1 $attempts); do
    if pm2 describe "$name" >/dev/null 2>&1 && pm2 describe "$name" | grep -q "status *online"; then
      return 0
    fi
    sleep 5
  done
  echo "PM2 process $name failed to become online" >&2
  return 1
}

wait_for_port() {
  local port=$1
  local attempts=${2:-10}
  for i in $(seq 1 $attempts); do
    if ss -tln | awk '{print $4}' | grep -q ":${port}$"; then
      return 0
    fi
    sleep 3
  done
  echo "Port ${port} did not open in time" >&2
  return 1
}

# Update and upgrade packages (force IPv4 to avoid apt IPv6 stalls)
retry 3 apt-get -o Acquire::ForceIPv4=true update
retry 3 apt-get -o Acquire::ForceIPv4=true upgrade -y

# Install base dependencies for Kubernetes tooling / terminal stack
retry 3 apt-get -o Acquire::ForceIPv4=true install -y \
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
retry 5 curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -s -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
chmod 644 "$KUBECONFIG"

# Install Node.js
retry 3 curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
retry 3 apt-get -o Acquire::ForceIPv4=true install -y nodejs

# Install PM2 globally
retry 3 npm install -g pm2

# Clone or update terminal backend code
mkdir -p /opt/terminal-server
cd /opt/terminal-server
if [ -d .git ]; then
  retry 5 git fetch --all --prune
  git reset --hard origin/main
else
  retry 5 git clone https://github.com/getsoss/learn-kubernetes .
fi

cat <<'ENV' > /opt/terminal-server/.env.local
NEXT_PUBLIC_WEBSOCKET_URL=ws://{{PROXY_IP}}:8080/session/{{SESSION_ID}}
ENV

retry 3 npm install
retry 3 npm run build

# Start Next.js (all interfaces) and websocket server through PM2
pm2 delete next-app >/dev/null 2>&1 || true
pm2 delete websocket-server >/dev/null 2>&1 || true
pm2 start npm --name next-app -- run start -- --hostname 0.0.0.0 --port 3000
pm2 start node --name websocket-server -- websocket-server.js
pm2 save
pm2 startup systemd -u root --hp /root

# Wait for PM2 processes and ports before registering session
wait_for_pm2 next-app 12
wait_for_pm2 websocket-server 12
wait_for_port 3000 20
wait_for_port 8889 20

# Register session with proxy
retry 5 curl -X POST http://{{PROXY_IP}}:8080/register-session \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "{{SESSION_ID}}", "vmIp": "'$(hostname -I | awk '{print $1}')'"}'
