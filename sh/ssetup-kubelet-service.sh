#!/bin/bash

# ============================================
# Setup kubelet systemd service for RISC-V
# ============================================

set -e

echo "============================================"
echo "Setting up kubelet systemd service"
echo "============================================"
echo ""

# --- CREATE KUBELET SERVICE FILE ---
echo "Step 1: Creating kubelet.service..."

sudo mkdir -p /etc/systemd/system/kubelet.service.d

cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "✓ kubelet.service created"
echo ""

# --- CREATE KUBELET DROP-IN CONFIG ---
echo "Step 2: Creating kubelet drop-in configuration..."

cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

echo "✓ kubelet drop-in config created"
echo ""

# --- CREATE KUBELET DEFAULTS FILE ---
echo "Step 3: Creating kubelet defaults file..."

sudo mkdir -p /etc/default

cat <<'EOF' | sudo tee /etc/default/kubelet
# Additional kubelet arguments
KUBELET_EXTRA_ARGS=
EOF

echo "✓ kubelet defaults file created"
echo ""

# --- CREATE REQUIRED DIRECTORIES ---
echo "Step 4: Creating required directories..."

sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /etc/kubernetes/pki

echo "✓ Required directories created"
echo ""

# --- ENABLE AND START KUBELET ---
echo "Step 5: Enabling kubelet service..."

sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet || true  # May fail before kubeadm init, that's OK

echo "✓ kubelet service enabled"
echo ""

# --- CHECK STATUS ---
echo "Checking kubelet service status..."
sudo systemctl status kubelet --no-pager || true

echo ""
echo "============================================"
echo "✓ kubelet service setup complete!"
echo "============================================"
echo ""
echo "Service files created:"
echo "  /etc/systemd/system/kubelet.service"
echo "  /etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
echo "  /etc/default/kubelet"
echo ""
echo "The kubelet service will start properly after running 'kubeadm init'"
echo ""
echo "Commands:"
echo "  sudo systemctl status kubelet   # Check status"
echo "  sudo systemctl restart kubelet  # Restart service"
echo "  sudo journalctl -u kubelet -f   # View logs"
echo "============================================"
