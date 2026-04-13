#!/bin/bash

# ============================================
# Beautiful Control Plane Setup for RISC-V K8s
# Fixed Version - Multi-distro support
# ============================================

# Configuration
DOCKERHUB_USER="cloudv10x"
K8S_VERSION="1.35.0"
PAUSE_VERSION="3.10"
FLANNEL_VERSION="0.28.0"
ETCD_VERSION="3.6.6"
COREDNS_VERSION="1.14.0"

set -e

# ============================================
# Color & Styling Functions
# ============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Text Styles
BOLD='\033[1m'
DIM='\033[2m'

# Spinner frames
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# Box drawing characters
BOX_TL="╔"
BOX_TR="╗"
BOX_BL="╚"
BOX_BR="╝"
BOX_H="═"
BOX_V="║"

# Progress characters
PROGRESS_COMPLETE="█"
PROGRESS_INCOMPLETE="░"

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
# UI Helper Functions (Fixed)
# ============================================

print_header() {
    clear
    local width=70
    echo -e "${CYAN}${BOLD}"
    echo "${BOX_TL}$(printf "${BOX_H}%.0s" $(seq 1 $((width-2))))${BOX_TR}"
    printf "${BOX_V}%-$((width-2))s${BOX_V}\n" " Kubernetes Control Plane Setup for RISC-V"
    printf "${BOX_V}%-$((width-2))s${BOX_V}\n" " Version: ${K8S_VERSION}"
    echo "${BOX_BL}$(printf "${BOX_H}%.0s" $(seq 1 $((width-2))))${BOX_BR}"
    echo -e "${NC}"
}

print_step_header() {
    local step=$1
    local title=$2
    echo ""
    echo -e "${BOLD}${BLUE}┌─ Step ${step}: ${title}${NC}"
}

print_step_footer() {
    local status=$1
    if [ "$status" = "success" ]; then
        echo -e "${GREEN}└─ ✓ Complete${NC}"
    else
        echo -e "${RED}└─ ✗ Failed${NC}"
    fi
    echo ""
}

spinner() {
    local pid=$1
    local message=$2
    local i=0
    
    # Save cursor position and hide cursor
    tput civis 2>/dev/null || true
    
    while kill -0 $pid 2>/dev/null; do
        printf "\r${CYAN}  ${SPINNER_FRAMES[$i]} ${NC}${message}..."
        i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done
    
    wait $pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "\r${GREEN}  ✓${NC} ${message}... ${GREEN}Done${NC}\n"
    else
        printf "\r${RED}  ✗${NC} ${message}... ${RED}Failed${NC}\n"
    fi
    
    # Show cursor again
    tput cnorm 2>/dev/null || true
    
    return $exit_code
}

run_with_spinner() {
    local message=$1
    shift
    local temp_output="/tmp/spinner_output_$$"
    
    # Run command in background and capture output
    (
        "$@" > "$temp_output" 2>&1
    ) &
    
    local pid=$!
    spinner $pid "$message"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ] && [ -f "$temp_output" ]; then
        echo -e "${DIM}${GRAY}$(cat "$temp_output")${NC}"
    fi
    
    rm -f "$temp_output"
    return $exit_code
}

print_info() {
    echo -e "${BLUE}  ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}  ✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}  ⚠${NC} $1"
}

print_error() {
    echo -e "${RED}  ✗${NC} $1"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r${CYAN}  Progress: [${NC}"
    printf "${GREEN}%${completed}s${NC}" | tr ' ' "${PROGRESS_COMPLETE}"
    printf "${GRAY}%${remaining}s${NC}" | tr ' ' "${PROGRESS_INCOMPLETE}"
    printf "${CYAN}] ${BOLD}${percentage}%%${NC}"
    
    if [ $current -eq $total ]; then
        echo ""
    fi
}

# ============================================
# Check Prerequisites
# ============================================

check_requirements() {
    # Check if running as root or with sudo
    if [ "$EUID" -eq 0 ]; then 
        print_warning "Running as root directly, sudo commands will be adjusted"
        SUDO=""
    else
        SUDO="sudo"
    fi
    
    # Check for required tools
    local missing_tools=()
    for tool in curl wget git; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_warning "Installing missing tools: ${missing_tools[*]}"
        $SUDO $PKG_INSTALL ${missing_tools[*]} 2>/dev/null || true
    fi
}

# ============================================
# Main Setup
# ============================================

# Detect package manager first
detect_package_manager

print_header

echo -e "${BOLD}${WHITE}Configuration:${NC}"
echo -e "${GRAY}  Package Manager:    ${NC}${PKG_MANAGER}"
echo -e "${GRAY}  DockerHub User:     ${NC}${DOCKERHUB_USER}"
echo -e "${GRAY}  Kubernetes:         ${NC}v${K8S_VERSION}"
echo -e "${GRAY}  Flannel:            ${NC}v${FLANNEL_VERSION}"
echo -e "${GRAY}  Pause Container:    ${NC}${PAUSE_VERSION}"
echo -e "${GRAY}  etcd:               ${NC}${ETCD_VERSION}"
echo -e "${GRAY}  CoreDNS:            ${NC}${COREDNS_VERSION}"
echo ""

read -p "$(echo -e ${YELLOW}Press Enter to start installation...${NC})"

# Check and install prerequisites
check_requirements

# ============================================
# Step 1: Cleanup
# ============================================

print_step_header "1" "Cleaning up existing installation"

run_with_spinner "Stopping kubelet" $SUDO systemctl stop kubelet 2>/dev/null || true
run_with_spinner "Resetting kubeadm" $SUDO kubeadm reset -f 2>/dev/null || true
run_with_spinner "Removing config directories" $SUDO rm -rf /etc/kubernetes/ /var/lib/etcd/ $HOME/.kube/
run_with_spinner "Cleaning up networking" bash -c "
    $SUDO ip link delete cni0 2>/dev/null || true
    $SUDO ip link delete flannel.1 2>/dev/null || true
    $SUDO rm -rf /var/lib/cni/ /etc/cni/net.d/* /run/flannel/
"
run_with_spinner "Removing old services" bash -c "
    $SUDO systemctl stop flanneld 2>/dev/null || true
    $SUDO systemctl disable flanneld 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/flanneld.service
    $SUDO systemctl daemon-reload
"
run_with_spinner "Flushing iptables" $SUDO iptables -F && $SUDO iptables -t nat -F && $SUDO iptables -t mangle -F && $SUDO iptables -X

print_step_footer "success"

# ============================================
# Step 2: Install Dependencies (FIXED)
# ============================================

print_step_header "2" "Installing dependencies"

run_with_spinner "Updating package lists" $SUDO $PKG_UPDATE
run_with_spinner "Upgrading packages" $SUDO $PKG_UPGRADE

# Install containerd and dependencies
print_info "Installing containerd and required packages..."
case $PKG_MANAGER in
    "apt-get")
        run_with_spinner "Installing packages" $SUDO $PKG_INSTALL containerd apt-transport-https ca-certificates curl gpg
        ;;
    "dnf"|"yum")
        # For RHEL/Fedora, some packages have different names
        run_with_spinner "Installing packages" $SUDO $PKG_INSTALL containerd ca-certificates curl gpg
        # Enable containerd service
        $SUDO systemctl enable containerd 2>/dev/null || true
        $SUDO systemctl start containerd 2>/dev/null || true
        ;;
esac

print_info "Configuring containerd..."
$SUDO mkdir -p /etc/containerd
if ! $SUDO test -f /etc/containerd/config.toml; then
    containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null 2>&1
fi

run_with_spinner "Enabling systemd cgroup" $SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
run_with_spinner "Setting custom pause image" $SUDO sed -i "s|sandbox_image = .*|sandbox_image = \"${DOCKERHUB_USER}/pause:${PAUSE_VERSION}\"|g" /etc/containerd/config.toml
run_with_spinner "Configuring CNI path" $SUDO sed -i 's|bin_dir = .*|bin_dir = "/opt/cni/bin"|g' /etc/containerd/config.toml

print_success "Pause image: ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
print_success "CNI bin dir: /opt/cni/bin"

run_with_spinner "Restarting containerd" $SUDO systemctl restart containerd
run_with_spinner "Enabling containerd" $SUDO systemctl enable containerd > /dev/null 2>&1

run_with_spinner "Disabling swap" bash -c "
    $SUDO swapoff -a
    $SUDO sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab 2>/dev/null || true
"

print_info "Loading kernel modules..."
cat <<EOF | $SUDO tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

run_with_spinner "Loading overlay module" $SUDO modprobe overlay 2>/dev/null || true
run_with_spinner "Loading br_netfilter module" $SUDO modprobe br_netfilter 2>/dev/null || true

print_info "Configuring sysctl..."
cat <<EOF | $SUDO tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

run_with_spinner "Applying sysctl settings" $SUDO sysctl --system > /dev/null 2>&1

print_info "Installing crictl..."
VERSION="v1.28.0"
(
    wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-riscv64.tar.gz
    $SUDO tar zxf crictl-$VERSION-linux-riscv64.tar.gz -C /usr/local/bin
    rm -f crictl-$VERSION-linux-riscv64.tar.gz
    cat <<EOF | $SUDO tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
) > /dev/null 2>&1 &
spinner $! "Installing crictl"

print_step_footer "success"

# ============================================
# Step 3: Setup kubelet Service
# ============================================

print_step_header "3" "Setting up kubelet service"

$SUDO mkdir -p /etc/systemd/system/kubelet.service.d /etc/default /var/lib/kubelet /etc/kubernetes/manifests /etc/kubernetes/pki /opt/cni/bin /etc/cni/net.d /run/flannel

print_info "Creating kubelet service files..."

cat <<'KUBELET_SERVICE' | $SUDO tee /etc/systemd/system/kubelet.service > /dev/null
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
KUBELET_SERVICE

cat <<'KUBELET_DROPIN' | $SUDO tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf > /dev/null
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBELET_DROPIN

cat <<'KUBELET_DEFAULTS' | $SUDO tee /etc/default/kubelet > /dev/null
KUBELET_EXTRA_ARGS=
KUBELET_DEFAULTS

run_with_spinner "Reloading systemd" $SUDO systemctl daemon-reload
run_with_spinner "Enabling kubelet" $SUDO systemctl enable kubelet > /dev/null 2>&1

print_step_footer "success"

# ============================================
# Step 4: Pull Custom Images
# ============================================

print_step_header "4" "Pulling custom Kubernetes images"

IMAGES=(
    "pause:${PAUSE_VERSION}"
    "kube-apiserver:${K8S_VERSION}"
    "kube-controller-manager:${K8S_VERSION}"
    "kube-scheduler:${K8S_VERSION}"
    "kube-proxy:${K8S_VERSION}"
    "etcd:${ETCD_VERSION}-riscv64"
    "coredns:${COREDNS_VERSION}"
    "flannel:${FLANNEL_VERSION}"
    "flannel-cni-plugin:latest"
)

TOTAL_IMAGES=${#IMAGES[@]}
CURRENT=0

for image in "${IMAGES[@]}"; do
    CURRENT=$((CURRENT + 1))
    progress_bar $CURRENT $TOTAL_IMAGES
    ($SUDO ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/${image} > /dev/null 2>&1) &
    spinner $! "Pulling ${image}"
done

print_info "Tagging images for kubeadm..."

ctr_retag() {
    $SUDO ctr -n k8s.io images rm "$2" 2>/dev/null || true
    $SUDO ctr -n k8s.io images tag "$1" "$2" > /dev/null 2>&1
}

ctr_retag docker.io/${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION} registry.k8s.io/kube-apiserver:v${K8S_VERSION}
ctr_retag docker.io/${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION} registry.k8s.io/kube-controller-manager:v${K8S_VERSION}
ctr_retag docker.io/${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION} registry.k8s.io/kube-scheduler:v${K8S_VERSION}
ctr_retag docker.io/${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION} registry.k8s.io/kube-proxy:v${K8S_VERSION}
ctr_retag docker.io/${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64 registry.k8s.io/etcd:${ETCD_VERSION}-0
ctr_retag docker.io/${DOCKERHUB_USER}/coredns:${COREDNS_VERSION} registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}
ctr_retag docker.io/${DOCKERHUB_USER}/pause:${PAUSE_VERSION} registry.k8s.io/pause:${PAUSE_VERSION}.1

print_success "All images tagged successfully"

print_step_footer "success"

# ============================================
# Step 5: Install CNI Plugins
# ============================================

print_step_header "5" "Installing CNI plugins"

CNI_VERSION="v1.5.1"
print_info "Downloading CNI plugins ${CNI_VERSION}..."

(
    wget -q https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-riscv64-${CNI_VERSION}.tgz
    $SUDO tar -xzf cni-plugins-linux-riscv64-${CNI_VERSION}.tgz -C /opt/cni/bin
    rm cni-plugins-linux-riscv64-${CNI_VERSION}.tgz
) > /dev/null 2>&1 &
spinner $! "Installing standard CNI plugins"

# Check if Go is installed for building Flannel CNI
if ! command -v go &> /dev/null; then
    print_warning "Go not found, skipping Flannel CNI build (will use existing or download)"
    # Try to download pre-built binary if available
    if [ ! -f /opt/cni/bin/flannel ]; then
        print_info "Attempting to download pre-built Flannel CNI..."
        $SUDO cp /opt/cni/bin/bridge /opt/cni/bin/flannel 2>/dev/null || print_warning "Flannel CNI plugin will be handled by Flannel DaemonSet"
    fi
else
    print_info "Building Flannel CNI plugin..."
    (
        cd /tmp
        rm -rf cni-plugin
        git clone --depth=1 https://github.com/flannel-io/cni-plugin.git > /dev/null 2>&1
        cd cni-plugin
        CGO_ENABLED=0 go build -o flannel . > /dev/null 2>&1
        $SUDO install -m 755 flannel /opt/cni/bin/flannel
        cd ~
        rm -rf /tmp/cni-plugin
    ) > /dev/null 2>&1 &
    spinner $! "Building Flannel CNI plugin"
fi

print_success "CNI plugins installed to /opt/cni/bin"

print_step_footer "success"

# ============================================
# Step 6: Initialize Control Plane
# ============================================

print_step_header "6" "Initializing Kubernetes control plane"

print_warning "This may take a few minutes..."

(
    $SUDO kubeadm init \
      --pod-network-cidr=10.244.0.0/16 \
      --kubernetes-version=v${K8S_VERSION} > /tmp/kubeadm_init.log 2>&1
    
    mkdir -p $HOME/.kube
    $SUDO cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    $SUDO chown $(id -u):$(id -g) $HOME/.kube/config
) &
spinner $! "Initializing control plane"

print_step_footer "success"

# ============================================
# Step 7: Configure Control Plane Node
# ============================================

print_step_header "7" "Configuring control plane node"

echo ""
echo -e "${YELLOW}${BOLD}  Allow pods to run on control plane?${NC}"
echo -e "${GRAY}  • Yes: Single-node cluster (control plane runs workloads)${NC}"
echo -e "${GRAY}  • No:  Multi-node cluster (control plane dedicated)${NC}"
echo ""
read -p "$(echo -e ${CYAN}  Choice [y/N]: ${NC})" -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    run_with_spinner "Removing control plane taint" kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    print_success "Control plane can now run pods"
else
    print_info "Control plane will remain dedicated"
fi

print_step_footer "success"

# ============================================
# Step 8: Install Helm
# ============================================

print_step_header "8" "Installing Helm"

if ! command -v helm &> /dev/null; then
    (curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null 2>&1) &
    spinner $! "Installing Helm"
else
    print_success "Helm already installed"
fi

print_step_footer "success"

# ============================================
# Step 9: Install Flannel CNI
# ============================================

print_step_header "9" "Installing Flannel CNI"

run_with_spinner "Adding Flannel Helm repo" bash -c "
    helm repo add flannel https://flannel-io.github.io/flannel/ > /dev/null 2>&1
    helm repo update > /dev/null 2>&1
"

run_with_spinner "Creating kube-flannel namespace" bash -c "
    kubectl create namespace kube-flannel > /dev/null 2>&1 || true
    kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged > /dev/null 2>&1
"

cat <<EOF > /tmp/flannel-values.yaml
podCidr: "10.244.0.0/16"
image:
  repository: ${DOCKERHUB_USER}/flannel
  tag: ${FLANNEL_VERSION}
flannel:
  backend: "vxlan"
EOF

(helm install flannel \
  --namespace kube-flannel \
  --values /tmp/flannel-values.yaml \
  flannel/flannel > /dev/null 2>&1) &
spinner $! "Installing Flannel"

print_step_footer "success"

# ============================================
# Step 10: Wait for Flannel
# ============================================

print_step_header "10" "Waiting for Flannel to initialize"

print_info "Waiting for Flannel pods..."

timeout=180
elapsed=0
while ! kubectl wait --for=condition=ready pod -l app=flannel -n kube-flannel --timeout=5s > /dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        print_warning "Flannel pods took longer than expected"
        break
    fi
    printf "\r${CYAN}  ${SPINNER_FRAMES[$((elapsed % ${#SPINNER_FRAMES[@]}))]}${NC} Waiting for Flannel pods... ${elapsed}s/${timeout}s"
    sleep 1
    elapsed=$((elapsed + 1))
done
echo ""

if [ -f /run/flannel/subnet.env ]; then
    print_success "Flannel subnet.env created"
else
    print_warning "subnet.env not found yet (may still be initializing)"
fi

print_step_footer "success"

# ============================================
# Step 11: Verify Installation
# ============================================

print_step_header "11" "Verifying installation"

sleep 5

run_with_spinner "Waiting for nodes to be ready" kubectl wait --for=condition=ready node --all --timeout=60s > /dev/null 2>&1 || true

print_step_footer "success"

# ============================================
# Summary
# ============================================

clear
print_header

echo -e "${GREEN}${BOLD}✓ Installation Complete!${NC}"
echo ""

echo -e "${BOLD}${WHITE}Cluster Status:${NC}"
kubectl get nodes --no-headers 2>/dev/null | while read line; do
    node=$(echo $line | awk '{print $1}')
    status=$(echo $line | awk '{print $2}')
    
    if [ "$status" = "Ready" ]; then
        echo -e "${GREEN}  ✓${NC} ${node} - ${GREEN}${status}${NC}"
    else
        echo -e "${YELLOW}  ⚠${NC} ${node} - ${YELLOW}${status}${NC}"
    fi
done
echo ""

echo -e "${BOLD}${WHITE}System Pods:${NC}"
kubectl get pods -n kube-system --no-headers 2>/dev/null | while read line; do
    pod=$(echo $line | awk '{print $1}')
    status=$(echo $line | awk '{print $3}')
    
    if [ "$status" = "Running" ]; then
        echo -e "${GREEN}  ✓${NC} ${pod}"
    else
        echo -e "${YELLOW}  ⚠${NC} ${pod} - ${status}"
    fi
done
echo ""

echo -e "${BOLD}${WHITE}Flannel Pods:${NC}"
kubectl get pods -n kube-flannel --no-headers 2>/dev/null | while read line; do
    pod=$(echo $line | awk '{print $1}')
    status=$(echo $line | awk '{print $3}')
    
    if [ "$status" = "Running" ]; then
        echo -e "${GREEN}  ✓${NC} ${pod}"
    else
        echo -e "${YELLOW}  ⚠${NC} ${pod} - ${status}"
    fi
done
echo ""

echo -e "${BOLD}${CYAN}Join Worker Nodes:${NC}"
echo -e "${GRAY}Run this command on worker nodes:${NC}"
echo ""
JOIN_CMD=$($SUDO kubeadm token create --print-join-command 2>/dev/null)
echo -e "${WHITE}  ${JOIN_CMD}${NC}"
echo ""

echo -e "${BOLD}${CYAN}Useful Commands:${NC}"
echo -e "${GRAY}  kubectl get nodes                          ${NC}# Check node status"
echo -e "${GRAY}  kubectl get pods -A                        ${NC}# Check all pods"
echo -e "${GRAY}  kubectl logs -n kube-flannel -l app=flannel${NC}# View Flannel logs"
echo ""

echo -e "${DIM}${GRAY}Setup completed at $(date)${NC}"
echo ""
