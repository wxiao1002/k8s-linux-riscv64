#!/bin/bash

# ============================================
# Worker Node Setup (RISC-V Only)
# 精简版：只部署，不负责镜像拉取
# ============================================

# Configuration - MUST MATCH CONTROL PLANE!
K8S_VERSION="1.35.0"
TARGET_PAUSE="3.10.1"  # K8s 1.35.0 要求的 pause 版本
K8S_TARBALL_URL="https://github.com/alitariq4589/kubernetes-riscv/releases/download/v${K8S_VERSION}/kubernetes-v${K8S_VERSION}-riscv64-linux.tar.gz"

# Get join command from argument
JOIN_COMMAND="$@"

# ============================================
# Color & Styling Functions
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║           Kubernetes Worker Node Setup for RISC-V                  ║"
    echo "║                         Deploy Only                                ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}┌─ $1${NC}"
}

print_success() {
    echo -e "${GREEN}└─ ✓ $1${NC}"
}

print_error() {
    echo -e "${RED}└─ ✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}  ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}  ⚠${NC} $1"
}

# ============================================
# Initial Checks
# ============================================

print_header

if [ -z "$JOIN_COMMAND" ]; then
    echo -e "${RED}${BOLD}ERROR: No join command provided${NC}"
    echo ""
    echo -e "${YELLOW}Usage: ./setup-worker.sh <join-command>${NC}"
    echo ""
    echo -e "${CYAN}Example:${NC}"
    echo "  ./setup-worker.sh kubeadm join 172.26.164.69:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz..."
    echo ""
    echo -e "${CYAN}Get the join command from your control plane:${NC}"
    echo "  sudo kubeadm token create --print-join-command"
    exit 1
fi

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then 
    SUDO=""
else
    if ! sudo -v &> /dev/null; then
        print_error "User does not have sudo privileges"
        exit 1
    fi
    SUDO="sudo"
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "riscv64" ]; then
    print_error "This script is for RISC-V only. Detected: $ARCH"
    exit 1
fi

echo ""
echo -e "${BOLD}${WHITE}System Information:${NC}"
echo -e "${GRAY}  Architecture:       ${NC}${ARCH}"
echo -e "${GRAY}  K8s Version:        ${NC}${K8S_VERSION}"
echo -e "${GRAY}  Pause Version:      ${NC}${TARGET_PAUSE}"
echo ""

read -p "$(echo -e ${YELLOW}Press Enter to start installation...${NC})"

set -e  # Exit on any error

# ============================================
# Step 1: Cleanup
# ============================================

print_section "Step 1: Cleaning up existing configuration"

print_info "Stopping services..."
$SUDO systemctl stop kubelet 2>/dev/null || true
$SUDO systemctl stop flanneld 2>/dev/null || true

print_info "Resetting kubeadm..."
$SUDO kubeadm reset -f 2>/dev/null || true

print_info "Removing configuration directories..."
$SUDO rm -rf /etc/kubernetes/ /var/lib/kubelet/ /var/lib/etcd/ $HOME/.kube/

print_info "Cleaning up networking..."
$SUDO ip link delete cni0 2>/dev/null || true
$SUDO ip link delete flannel.1 2>/dev/null || true
$SUDO rm -rf /var/lib/cni/ /etc/cni/net.d/* 2>/dev/null || true

print_info "Flushing iptables..."
$SUDO iptables -F && $SUDO iptables -t nat -F && $SUDO iptables -t mangle -F && $SUDO iptables -X 2>/dev/null || true

print_success "Cleanup complete"

# ============================================
# Step 2: Install Dependencies
# ============================================

print_section "Step 2: Installing dependencies"

print_info "Installing required packages..."
$SUDO dnf makecache --quiet
$SUDO dnf install -y -q containerd conntrack-tools ethtool socat iptables-ebtables ca-certificates curl wget

print_info "Configuring containerd..."
$SUDO mkdir -p /etc/containerd

# 生成默认配置（如果不存在）
if [ ! -f /etc/containerd/config.toml ]; then
    print_info "Generating default containerd config..."
    containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
fi

# 启用 systemd cgroup 驱动
print_info "Enabling systemd cgroup driver..."
$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 配置 pause 镜像
print_info "Configuring pause image..."
$SUDO sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:${TARGET_PAUSE}\"|" /etc/containerd/config.toml

# 启动 containerd
print_info "Starting containerd..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable containerd > /dev/null 2>&1 || true
$SUDO systemctl restart containerd

# 等待 containerd 就绪
echo -ne "${YELLOW}Waiting for containerd...${NC}"
for i in {1..10}; do
    if $SUDO crictl version >/dev/null 2>&1; then
        echo -e "${GREEN} Ready!${NC}"
        break
    fi
    echo -ne "."
    sleep 2
    if [ $i -eq 10 ]; then
        echo -e "${RED}\n✗ Containerd failed to start${NC}"
        $SUDO systemctl status containerd --no-pager
        exit 1
    fi
done

print_success "containerd configured"

# 系统配置
print_info "Disabling swap..."
$SUDO swapoff -a
$SUDO sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab 2>/dev/null || true

print_info "Loading kernel modules..."
cat <<EOF | $SUDO tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

$SUDO modprobe overlay 2>/dev/null || true
$SUDO modprobe br_netfilter 2>/dev/null || true

print_info "Configuring sysctl..."
cat <<EOF | $SUDO tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

$SUDO sysctl --system > /dev/null 2>&1

print_success "System configured"

# ============================================
# Step 3: Verify Required Images
# ============================================

print_section "Step 3: Verifying required images"

REQUIRED_IMAGES=(
    "registry.k8s.io/pause:${TARGET_PAUSE}"
    "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
)

missing=false
for img in "${REQUIRED_IMAGES[@]}"; do
    echo -ne "${CYAN}Checking: ${img} ... ${NC}"
    if $SUDO crictl inspecti "$img" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        missing=true
    fi
done

if [ "$missing" = true ]; then
    echo -e "\n${RED}${BOLD}Missing required images!${NC}"
    echo -e "${YELLOW}Please run the image puller script on this node first.${NC}"
    exit 1
fi

print_success "All required images present"

# ============================================
# Step 4: Install Kubernetes Binaries
# ============================================

print_section "Step 4: Installing Kubernetes binaries"

if [ -f /usr/local/bin/kubelet ] && [ -f /usr/local/bin/kubeadm ]; then
    print_success "Kubernetes binaries already installed"
else
    print_info "Downloading Kubernetes ${K8S_VERSION} for RISC-V..."
    
    cd /tmp
    rm -rf kubernetes-riscv-install
    mkdir -p kubernetes-riscv-install
    cd kubernetes-riscv-install
    
    if ! wget -q --show-progress "${K8S_TARBALL_URL}" -O kubernetes.tar.gz; then
        print_info "Trying curl..."
        if ! curl -L "${K8S_TARBALL_URL}" -o kubernetes.tar.gz; then
            print_error "Failed to download Kubernetes tarball"
            echo -e "${GRAY}URL: ${K8S_TARBALL_URL}${NC}"
            exit 1
        fi
    fi
    
    print_info "Extracting..."
    tar -xzf kubernetes.tar.gz
    
    print_info "Installing binaries..."
    $SUDO cp bin/* /usr/local/bin/ 2>/dev/null || $SUDO cp kube* /usr/local/bin/
    $SUDO chmod +x /usr/local/bin/kube*
    
    # 安装 CNI 插件
    $SUDO mkdir -p /opt/cni/bin
    $SUDO cp cni/* /opt/cni/bin/ 2>/dev/null || true
    $SUDO chmod +x /opt/cni/bin/* 2>/dev/null || true
    
    cd /tmp
    rm -rf kubernetes-riscv-install
fi

print_success "Kubernetes binaries installed"

# ============================================
# Step 5: Setup Kubelet Service
# ============================================

print_section "Step 5: Setting up kubelet service"

$SUDO tee /etc/systemd/system/kubelet.service > /dev/null <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

$SUDO mkdir -p /etc/systemd/system/kubelet.service.d
$SUDO tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf > /dev/null <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable kubelet

print_success "Kubelet service configured"

# ============================================
# Step 6: Join Cluster
# ============================================

print_section "Step 6: Joining the cluster"

echo -e "${CYAN}Running join command...${NC}"
$SUDO mkdir -p /etc/kubernetes/manifests
$SUDO mkdir -p /var/lib/kubelet

if $SUDO $JOIN_COMMAND; then
    print_success "Node joined successfully"
else
    print_error "Failed to join cluster"
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "  1. Ensure control plane is reachable"
    echo "  2. Check if token is still valid"
    echo "  3. Verify network connectivity to port 6443"
    exit 1
fi

# ============================================
# Step 7: Verify
# ============================================

print_section "Step 7: Verifying setup"

sleep 3

echo ""
if systemctl is-active --quiet kubelet; then
    print_success "Kubelet is running"
else
    print_warning "Kubelet not running yet (may take a moment)"
fi

# ============================================
# Summary
# ============================================

clear
print_header

echo -e "${GREEN}${BOLD}✓ Worker Node Setup Complete!${NC}\n"

echo -e "${BOLD}${WHITE}Next Steps:${NC}\n"

echo -e "${CYAN}On control plane, verify the node joined:${NC}"
echo -e "${GRAY}   kubectl get nodes${NC}\n"

echo -e "${CYAN}Monitor kubelet logs on this node:${NC}"
echo -e "${GRAY}   sudo journalctl -u kubelet -f${NC}\n"

echo -e "${YELLOW}${BOLD}Troubleshooting:${NC}\n"

echo -e "${CYAN}Check containerd pause config:${NC}"
echo -e "${GRAY}   sudo grep sandbox_image /etc/containerd/config.toml${NC}\n"

echo -e "${CYAN}Restart services:${NC}"
echo -e "${GRAY}   sudo systemctl restart containerd && sudo systemctl restart kubelet${NC}\n"

echo -e "${DIM}${GRAY}Setup completed at $(date)${NC}\n"
