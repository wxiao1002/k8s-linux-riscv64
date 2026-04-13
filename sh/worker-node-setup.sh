#!/bin/bash

# ============================================
# Worker Node Setup (x86 or RISC-V) - Fedora/RISC-V Optimized
# Multi-distro support with package manager detection
# ============================================

# Configuration - MUST MATCH CONTROL PLANE!
DOCKERHUB_USER="cloudv10x"  # Your DockerHub username
PAUSE_VERSION="3.10"
K8S_VERSION="v1.35.0"  # Version of your custom RISC-V binaries
K8S_TARBALL_URL="https://github.com/alitariq4589/kubernetes-riscv/releases/download/${K8S_VERSION}/kubernetes-${K8S_VERSION}-riscv64-linux.tar.gz"

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
DIM='\033[2m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║           Kubernetes Worker Node Setup for Multi-Arch              ║"
    echo "║                     x86_64 / RISC-V Support                        ║"
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
# Package Manager Detection
# ============================================

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        PKG_UPDATE="apt-get update -qq"
        PKG_UPGRADE="apt-get upgrade -y -qq"
        PKG_INSTALL="apt-get install -y -qq"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf makecache --quiet"
        PKG_UPGRADE="dnf upgrade -y -q"
        PKG_INSTALL="dnf install -y -q"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache -q"
        PKG_UPGRADE="yum update -y -q"
        PKG_INSTALL="yum install -y -q"
    else
        echo -e "${RED}Error: No supported package manager found (apt-get/dnf/yum)${NC}"
        exit 1
    fi
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
    print_warning "Running as root directly, sudo commands will be adjusted"
    SUDO=""
else
    # Check if user has sudo privileges
    if ! sudo -v &> /dev/null; then
        print_error "User does not have sudo privileges"
        exit 1
    fi
    SUDO="sudo"
fi

# Detect package manager
detect_package_manager

# Detect architecture
ARCH=$(uname -m)
echo ""
echo -e "${BOLD}${WHITE}System Information:${NC}"
echo -e "${GRAY}  Architecture:       ${NC}${ARCH}"
echo -e "${GRAY}  Package Manager:    ${NC}${PKG_MANAGER}"
echo -e "${GRAY}  DockerHub User:     ${NC}${DOCKERHUB_USER}"
echo -e "${GRAY}  Pause Version:      ${NC}${PAUSE_VERSION}"
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

print_info "Removing old services..."
$SUDO systemctl disable flanneld 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/flanneld.service
$SUDO rm -f /run/flannel/subnet.env
$SUDO systemctl daemon-reload

print_info "Flushing iptables..."
$SUDO iptables -F && $SUDO iptables -t nat -F && $SUDO iptables -t mangle -F && $SUDO iptables -X 2>/dev/null || true

print_info "Removing old CNI binaries..."
$SUDO rm -f /opt/cni/bin/*flannel* 2>/dev/null || true
$SUDO rm -f /usr/local/bin/flanneld 2>/dev/null || true

print_success "Cleanup complete"

# ============================================
# Step 2: Install Dependencies (FEDORA/RISC-V OPTIMIZED)
# ============================================

print_section "Step 2: Installing dependencies"

print_info "Updating package lists..."
$SUDO $PKG_UPDATE

print_info "Installing required packages..."
case $PKG_MANAGER in
    "apt-get")
        $SUDO $PKG_INSTALL containerd conntrack ethtool socat ebtables apt-transport-https ca-certificates curl gpg wget
        ;;
    "dnf"|"yum")
        # Fedora/RHEL package names
        print_info "Installing Fedora/RHEL packages..."
        $SUDO $PKG_INSTALL containerd conntrack-tools ethtool socat iptables-ebtables ca-certificates curl gnupg wget
        
        # Create containerd config directory
        $SUDO mkdir -p /etc/containerd
        
        # Generate default config if not exists
        if [ ! -f /etc/containerd/config.toml ]; then
            print_info "Generating default containerd config..."
            containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
        fi
        ;;
esac

print_info "Configuring containerd..."
$SUDO mkdir -p /etc/containerd

print_info "Enabling systemd cgroup driver..."
$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# --- CRITICAL: Configure custom pause image ---
print_info "Configuring custom pause image..."

# Detect containerd version
if command -v containerd &> /dev/null; then
    CONTAINERD_VERSION=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "1.0.0")
else
    CONTAINERD_VERSION="1.0.0"
    print_warning "containerd not found in PATH, assuming version ${CONTAINERD_VERSION}"
fi

CONTAINERD_MAJOR=$(echo "$CONTAINERD_VERSION" | cut -d. -f1)
CONTAINERD_MINOR=$(echo "$CONTAINERD_VERSION" | cut -d. -f2)

echo -e "${GRAY}  Detected containerd version: ${CONTAINERD_MAJOR}.${CONTAINERD_MINOR}${NC}"

# Configure based on version
if [ "$CONTAINERD_MAJOR" -ge 2 ]; then
    print_info "Using containerd v2.x configuration format..."
    
    # Check if pinned_images section exists, if not add it
    if ! grep -q "pinned_images" /etc/containerd/config.toml; then
        print_warning "pinned_images section not found, adding it..."
        cat <<EOF | $SUDO tee -a /etc/containerd/config.toml > /dev/null

[pinned_images]
sandbox = "${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
EOF
    else
        $SUDO sed -i "s|sandbox = '.*'|sandbox = '${DOCKERHUB_USER}/pause:${PAUSE_VERSION}'|g" /etc/containerd/config.toml
    fi
    
    # Verify
    if $SUDO grep -q "sandbox.*${DOCKERHUB_USER}/pause:${PAUSE_VERSION}" /etc/containerd/config.toml; then
        print_success "pinned_images.sandbox configured"
    else
        print_error "Failed to configure pinned_images.sandbox"
        echo -e "${GRAY}Current configuration:${NC}"
        $SUDO grep -A2 "pinned_images" /etc/containerd/config.toml 2>/dev/null || echo "  pinned_images section not found"
    fi
    
elif [ "$CONTAINERD_MAJOR" -eq 1 ]; then
    print_info "Using containerd v1.x configuration format..."
    
    if grep -q "sandbox_image" /etc/containerd/config.toml; then
        $SUDO sed -i "s|sandbox_image = \".*\"|sandbox_image = \"${DOCKERHUB_USER}/pause:${PAUSE_VERSION}\"|g" /etc/containerd/config.toml
    else
        print_warning "sandbox_image not found, adding it..."
        echo "sandbox_image = \"${DOCKERHUB_USER}/pause:${PAUSE_VERSION}\"" | $SUDO tee -a /etc/containerd/config.toml > /dev/null
    fi
    
    if $SUDO grep -q "sandbox_image.*${DOCKERHUB_USER}/pause:${PAUSE_VERSION}" /etc/containerd/config.toml; then
        print_success "sandbox_image configured"
    else
        print_error "Failed to configure sandbox_image"
    fi
    
else
    print_error "Unable to determine containerd version"
fi

print_info "Starting and enabling containerd..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable containerd > /dev/null 2>&1 || true
$SUDO systemctl restart containerd
sleep 2

# Verify containerd is running
if systemctl is-active --quiet containerd; then
    print_success "containerd is running"
else
    print_error "containerd failed to start"
    $SUDO systemctl status containerd --no-pager
fi

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
# Step 3: Install Kubernetes
# ============================================

print_section "Step 3: Installing Kubernetes"

if [ "$ARCH" = "x86_64" ]; then
    print_info "Installing Kubernetes for x86_64 from official repos..."
    
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        # Debian/Ubuntu
        $SUDO mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | $SUDO tee /etc/apt/sources.list.d/kubernetes.list
        
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq kubelet kubeadm kubectl
        $SUDO apt-mark hold kubelet kubeadm kubectl
    else
        # RHEL/Fedora
        cat <<EOF | $SUDO tee /etc/yum.repos.d/kubernetes.repo > /dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF
        $SUDO $PKG_UPDATE
        $SUDO $PKG_INSTALL kubelet kubeadm kubectl
    fi
    
elif [ "$ARCH" = "riscv64" ]; then
    print_info "Installing Kubernetes for RISC-V from custom binaries..."
    
    # Check if binaries already installed
    if [ -f /usr/local/bin/kubelet ] && [ -f /usr/local/bin/kubeadm ] && [ -f /usr/local/bin/kubectl ]; then
        print_success "Kubernetes binaries already installed"
    else
        print_info "Downloading Kubernetes ${K8S_VERSION} for RISC-V..."
        
        cd /tmp
        rm -rf kubernetes-riscv-install
        mkdir -p kubernetes-riscv-install
        cd kubernetes-riscv-install
        
        if ! wget -q --show-progress "${K8S_TARBALL_URL}" -O kubernetes.tar.gz; then
            print_error "Failed to download Kubernetes tarball"
            echo -e "${GRAY}URL: ${K8S_TARBALL_URL}${NC}"
            echo -e "${YELLOW}Trying alternative download method...${NC}"
            
            # Try with curl if wget fails
            if curl -L "${K8S_TARBALL_URL}" -o kubernetes.tar.gz; then
                print_success "Downloaded with curl"
            else
                print_error "Both wget and curl failed"
                exit 1
            fi
        fi
        
        print_info "Extracting tarball..."
        tar -xzf kubernetes.tar.gz
        
        # Run the install script
        if [ -f install.sh ]; then
            print_info "Running install script..."
            $SUDO bash install.sh
        else
            # Manual installation
            print_info "Installing binaries manually..."
            $SUDO cp -r bin/* /usr/local/bin/ 2>/dev/null || $SUDO cp kube* /usr/local/bin/
            $SUDO chmod +x /usr/local/bin/kube*
            
            # Install CNI plugins
            $SUDO mkdir -p /opt/cni/bin
            $SUDO cp -r cni/* /opt/cni/bin/ 2>/dev/null || true
            $SUDO chmod +x /opt/cni/bin/* 2>/dev/null || true
        fi
        
        cd /tmp
        rm -rf kubernetes-riscv-install
    fi
    
    # Verify installation
    if [ ! -f /usr/local/bin/kubelet ]; then
        print_error "kubelet not found in /usr/local/bin/"
        exit 1
    fi
    
    print_success "Kubernetes binaries installed"
    
else
    print_error "Unsupported architecture: $ARCH"
    exit 1
fi

print_success "Kubernetes installed"

# ============================================
# Step 4: Setup Kubelet Service (for RISC-V)
# ============================================

if [ "$ARCH" = "riscv64" ]; then
    print_section "Step 4: Setting up kubelet service for RISC-V"
    
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
fi

# ============================================
# Step 5: Join Cluster
# ============================================

print_section "Step 5: Joining the cluster"

echo -e "${CYAN}Running: $SUDO $JOIN_COMMAND${NC}"
echo ""

# Create necessary directories
$SUDO mkdir -p /etc/kubernetes/manifests
$SUDO mkdir -p /var/lib/kubelet

if $SUDO $JOIN_COMMAND; then
    print_success "Node joined successfully"
else
    print_error "Failed to join cluster"
    echo ""
    echo -e "${YELLOW}Troubleshooting tips:${NC}"
    echo "  1. Ensure the control plane is reachable"
    echo "  2. Check if the token is still valid"
    echo "  3. Verify network connectivity to port 6443"
    echo "  4. Check containerd status: sudo systemctl status containerd"
    exit 1
fi

# ============================================
# Step 6: Verify Setup
# ============================================

print_section "Step 6: Verifying setup"

sleep 5

echo ""
echo -e "${BOLD}${WHITE}Kubelet Status:${NC}"
if systemctl is-active --quiet kubelet; then
    print_success "Kubelet is running"
else
    print_warning "Kubelet not running yet"
    echo -e "${GRAY}Checking kubelet logs...${NC}"
    $SUDO journalctl -u kubelet --no-pager -n 10
fi

echo ""
echo -e "${BOLD}${WHITE}Pause Image Configuration:${NC}"
if [ "$CONTAINERD_MAJOR" -ge 2 ]; then
    $SUDO grep -A2 "pinned_images" /etc/containerd/config.toml 2>/dev/null | grep sandbox || echo "  Not found"
else
    $SUDO grep "sandbox_image" /etc/containerd/config.toml 2>/dev/null || echo "  Not found"
fi

echo ""
echo -e "${BOLD}${WHITE}CNI Plugins:${NC}"
if [ -d /opt/cni/bin ]; then
    ls -1 /opt/cni/bin/ 2>/dev/null | head -10 | while read plugin; do
        echo -e "  ${GRAY}•${NC} $plugin"
    done
else
    print_warning "/opt/cni/bin not found"
fi

# ============================================
# Summary
# ============================================

clear
print_header

echo -e "${GREEN}${BOLD}✓ Worker Node Setup Complete!${NC}"
echo ""

echo -e "${BOLD}${WHITE}Next Steps:${NC}"
echo ""

echo -e "${CYAN}1. On control plane, verify the node joined:${NC}"
echo -e "${GRAY}   kubectl get nodes${NC}"
echo ""

echo -e "${CYAN}2. Check node status (should show Ready):${NC}"
echo -e "${GRAY}   kubectl describe node $(hostname)${NC}"
echo ""

echo -e "${CYAN}3. Monitor Flannel pods on this node:${NC}"
echo -e "${GRAY}   kubectl get pods -n kube-flannel -o wide | grep $(hostname)${NC}"
echo ""

echo -e "${YELLOW}${BOLD}Troubleshooting:${NC}"
echo ""

echo -e "${CYAN}If pause container errors occur:${NC}"
if [ "$CONTAINERD_MAJOR" -ge 2 ]; then
    echo -e "${GRAY}   • Verify: sudo grep -A2 'pinned_images' /etc/containerd/config.toml${NC}"
else
    echo -e "${GRAY}   • Verify: sudo grep sandbox_image /etc/containerd/config.toml${NC}"
fi
echo -e "${GRAY}   • Restart: sudo systemctl restart containerd && sudo systemctl restart kubelet${NC}"
echo ""

echo -e "${CYAN}Monitor kubelet logs:${NC}"
echo -e "${GRAY}   sudo journalctl -u kubelet -f${NC}"
echo ""

echo -e "${CYAN}Check containerd status:${NC}"
echo -e "${GRAY}   sudo systemctl status containerd${NC}"
echo ""

echo -e "${DIM}${GRAY}Setup completed at $(date)${NC}"
echo ""
