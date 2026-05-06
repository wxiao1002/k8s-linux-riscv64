#!/bin/bash

# ============================================
# Kubernetes Control Plane Setup for RISC-V (Fedora Edition)
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

BOX_TL="╔"
BOX_TR="╗"
BOX_BL="╚"
BOX_BR="╝"
BOX_H="═"
BOX_V="║"

print_header() {
    clear
    local width=70
    echo -e "${CYAN}${BOLD}"
    echo "${BOX_TL}$(printf "${BOX_H}%.0s" $(seq 1 $((width-2))))${BOX_TR}"
    printf "${BOX_V}%-$((width-2))s${BOX_V}\n" " Kubernetes Control Plane Setup for RISC-V (Fedora)"
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
    
    tput cnorm 2>/dev/null || true
    
    return $exit_code
}

run_with_spinner() {
    local message=$1
    shift
    
    (
        "$@" > /tmp/spinner_output_$$ 2>&1
    ) &
    
    local pid=$!
    spinner $pid "$message"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo -e "${DIM}${GRAY}$(cat /tmp/spinner_output_$$)${NC}"
    fi
    
    rm -f /tmp/spinner_output_$$
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

# ============================================
# Main Setup
# ============================================

print_header

echo -e "${BOLD}${WHITE}Configuration:${NC}"
echo -e "${GRAY}  DockerHub User:     ${NC}${DOCKERHUB_USER}"
echo -e "${GRAY}  Kubernetes:         ${NC}v${K8S_VERSION}"
echo -e "${GRAY}  Flannel:            ${NC}v${FLANNEL_VERSION}"
echo -e "${GRAY}  Pause Container:    ${NC}${PAUSE_VERSION}"
echo -e "${GRAY}  etcd:               ${NC}${ETCD_VERSION}"
echo -e "${GRAY}  CoreDNS:            ${NC}${COREDNS_VERSION}"
echo ""

read -p "$(echo -e ${YELLOW}Press Enter to start installation...${NC})"

# ============================================
# Step 1: Cleanup
# ============================================

print_step_header "1" "Cleaning up existing installation"

run_with_spinner "Stopping kubelet" sudo systemctl stop kubelet 2>/dev/null || true
run_with_spinner "Resetting kubeadm" sudo kubeadm reset -f 2>/dev/null || true
run_with_spinner "Removing config directories" sudo rm -rf /etc/kubernetes/ /var/lib/etcd/ $HOME/.kube/
run_with_spinner "Cleaning up networking" bash -c "
    sudo ip link delete cni0 2>/dev/null || true
    sudo ip link delete flannel.1 2>/dev/null || true
    sudo rm -rf /var/lib/cni/ /etc/cni/net.d/* /run/flannel/
"
run_with_spinner "Removing old services" bash -c "
    sudo systemctl stop flanneld 2>/dev/null || true
    sudo systemctl disable flanneld 2>/dev/null || true
    sudo rm -f /etc/systemd/system/flanneld.service
    sudo systemctl daemon-reload
"
run_with_spinner "Flushing iptables" sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

print_step_footer "success"

# ============================================
# Step 2: Install Dependencies (Fedora)
# ============================================

print_step_header "2" "Installing dependencies (Fedora)"

run_with_spinner "Updating package lists" sudo dnf makecache --refresh -q
run_with_spinner "Upgrading packages" sudo dnf upgrade -y -q

print_info "Installing required packages..."
sudo dnf install -y -q \
    containerd \
    ca-certificates \
    curl \
    gnupg \
    wget \
    git \
    golang \
    conntrack \
    socat \
    iproute-tc \
    2>/dev/null

print_success "Packages installed"

print_info "Configuring containerd..."
sudo mkdir -p /etc/containerd

# Generate default config if not exists
if [ ! -f /etc/containerd/config.toml ]; then
    sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null 2>&1
fi

run_with_spinner "Enabling systemd cgroup" sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
run_with_spinner "Setting custom pause image" sudo sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:${PAUSE_VERSION}.1\"|g" /etc/containerd/config.toml
run_with_spinner "Configuring CNI path" sudo sed -i 's|bin_dir = .*|bin_dir = "/opt/cni/bin"|g' /etc/containerd/config.toml

print_success "Pause image: registry.k8s.io/pause:${PAUSE_VERSION}.1"
print_success "CNI bin dir: /opt/cni/bin"

run_with_spinner "Starting containerd" sudo systemctl start containerd
run_with_spinner "Enabling containerd" sudo systemctl enable containerd > /dev/null 2>&1

# Disable swap (Fedora)
run_with_spinner "Disabling swap" bash -c "
    sudo swapoff -a
    sudo sed -i '/swap/d' /etc/fstab
"

# Disable firewall (optional, simplifies networking)
print_info "Configuring firewall..."
run_with_spinner "Disabling firewalld" sudo systemctl disable --now firewalld 2>/dev/null || true

# Disable SELinux (required for container networking)
print_info "Configuring SELinux..."
if [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
    run_with_spinner "Setting SELinux to permissive" sudo setenforce 0 2>/dev/null || true
    sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
    print_warning "SELinux set to permissive (required for Kubernetes)"
fi

print_info "Loading kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

run_with_spinner "Loading overlay module" sudo modprobe overlay 2>/dev/null || true
run_with_spinner "Loading br_netfilter module" sudo modprobe br_netfilter 2>/dev/null || true

print_info "Configuring sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

run_with_spinner "Applying sysctl settings" sudo sysctl --system > /dev/null 2>&1

print_info "Installing crictl..."
CRICTL_VERSION="v1.28.0"
(
    if [ ! -f /usr/local/bin/crictl ]; then
        wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-riscv64.tar.gz
        sudo tar zxf crictl-${CRICTL_VERSION}-linux-riscv64.tar.gz -C /usr/local/bin
        rm -f crictl-${CRICTL_VERSION}-linux-riscv64.tar.gz
    fi
    cat <<EOF | sudo tee /etc/crictl.yaml > /dev/null
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

sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mkdir -p /etc/default
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /etc/kubernetes/pki
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d
sudo mkdir -p /run/flannel

print_info "Creating kubelet service files..."

cat <<'KUBELET_SERVICE' | sudo tee /etc/systemd/system/kubelet.service > /dev/null
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
KUBELET_SERVICE

cat <<'KUBELET_DROPIN' | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf > /dev/null
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBELET_DROPIN

cat <<'KUBELET_DEFAULTS' | sudo tee /etc/default/kubelet > /dev/null
KUBELET_EXTRA_ARGS=
KUBELET_DEFAULTS

print_info "Creating symlinks for compatibility..."
for bin in kubeadm kube-apiserver kube-controller-manager kubectl kubelet kube-proxy kube-scheduler; do
    if [ -f /usr/local/bin/$bin ] && [ ! -f /usr/bin/$bin ]; then
        sudo ln -sf /usr/local/bin/$bin /usr/bin/$bin
        print_success "Linked /usr/bin/$bin -> /usr/local/bin/$bin"
    fi
done

run_with_spinner "Reloading systemd" sudo systemctl daemon-reload
run_with_spinner "Enabling kubelet" sudo systemctl enable kubelet > /dev/null 2>&1

print_step_footer "success"

# ============================================
# Step 4: Pull Custom Images Directly to registry.k8s.io
# ============================================

print_step_header "4" "Pulling Kubernetes images directly as registry.k8s.io"

# 定义需要拉取的镜像，直接使用 registry.k8s.io 命名空间
declare -A IMAGES_MAP
IMAGES_MAP["registry.k8s.io/pause:${PAUSE_VERSION}.1"]="${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
IMAGES_MAP["registry.k8s.io/kube-apiserver:v${K8S_VERSION}"]="${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"
IMAGES_MAP["registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"]="${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"
IMAGES_MAP["registry.k8s.io/kube-scheduler:v${K8S_VERSION}"]="${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"
IMAGES_MAP["registry.k8s.io/kube-proxy:v${K8S_VERSION}"]="${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"
IMAGES_MAP["registry.k8s.io/etcd:${ETCD_VERSION}-0"]="${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"
IMAGES_MAP["registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}"]="${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"

TOTAL_IMAGES=${#IMAGES_MAP[@]}
CURRENT=0
PULLED_COUNT=0
SKIPPED_COUNT=0

echo ""
echo -e "${BOLD}${WHITE}Total images to process: ${TOTAL_IMAGES}${NC}"
echo ""

for target_image in "${!IMAGES_MAP[@]}"; do
    CURRENT=$((CURRENT + 1))
    source_image="docker.io/${IMAGES_MAP[$target_image]}"
    
    echo -e "${BOLD}${WHITE}[${CURRENT}/${TOTAL_IMAGES}]${NC} ${GRAY}${target_image}${NC}"
    echo -e "  ${DIM}Source: ${source_image}${NC}"
    
    # 检查目标镜像是否已存在
    if sudo ctr -n k8s.io images check "name==${target_image}" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Target already exists, skipping${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo ""
        continue
    fi
    
    # 检查源镜像是否存在
    if ! sudo ctr -n k8s.io images check "name==${source_image}" > /dev/null 2>&1; then
        echo -e "  ${CYAN}⬇ Pulling source image...${NC}"
        sudo ctr -n k8s.io images pull ${source_image}
        if [ $? -ne 0 ]; then
            echo -e "  ${RED}✗ Failed to pull source image${NC}"
            echo ""
            continue
        fi
    else
        echo -e "  ${GREEN}✓ Source image already exists${NC}"
    fi
    
    # 直接打标签到目标镜像
    echo -e "  ${CYAN}⬆ Tagging to target...${NC}"
    sudo ctr -n k8s.io images tag ${source_image} ${target_image}
    
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Successfully tagged${NC}"
        PULLED_COUNT=$((PULLED_COUNT + 1))
    else
        echo -e "  ${RED}✗ Tag failed${NC}"
    fi
    echo ""
done

# Summary
echo -e "${BOLD}${WHITE}────────────────────────────────────────${NC}"
echo -e "${BOLD}Image Processing Summary:${NC}"
echo -e "  Total:    ${BOLD}${TOTAL_IMAGES}${NC}"
echo -e "  Tagged:   ${CYAN}${PULLED_COUNT}${NC}"
echo -e "  Skipped:  ${GREEN}${SKIPPED_COUNT}${NC}"
echo -e "${BOLD}${WHITE}────────────────────────────────────────${NC}"
echo ""

# 验证所有必需的镜像都已存在
print_info "Verifying all required images..."
MISSING_IMAGES=0
for target_image in "${!IMAGES_MAP[@]}"; do
    if ! sudo ctr -n k8s.io images check "name==${target_image}" > /dev/null 2>&1; then
        print_error "Missing: ${target_image}"
        MISSING_IMAGES=$((MISSING_IMAGES + 1))
    fi
done

if [ $MISSING_IMAGES -eq 0 ]; then
    print_success "All required images are present"
else
    print_error "${MISSING_IMAGES} images are missing. Please check the errors above."
    exit 1
fi

print_step_footer "success"

# ============================================
# Step 5: Install CNI Plugins
# ============================================

print_step_header "5" "Installing CNI plugins"

CNI_VERSION="v1.5.1"
print_info "Downloading CNI plugins ${CNI_VERSION}..."

if [ ! -f /opt/cni/bin/bridge ]; then
    (
        wget -q https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-riscv64-${CNI_VERSION}.tgz
        sudo tar -xzf cni-plugins-linux-riscv64-${CNI_VERSION}.tgz -C /opt/cni/bin
        rm cni-plugins-linux-riscv64-${CNI_VERSION}.tgz
    ) > /dev/null 2>&1 &
    spinner $! "Installing standard CNI plugins"
else
    print_success "CNI plugins already installed"
fi

# Build Flannel CNI plugin
print_info "Building Flannel CNI plugin..."
if [ ! -f /opt/cni/bin/flannel ]; then
    timeout 120 bash -c '
        cd /tmp
        rm -rf cni-plugin
        git clone --depth=1 https://kgithub.com/flannel-io/cni-plugin.git 2>/dev/null
        cd cni-plugin
        CGO_ENABLED=0 go build -o flannel . 2>/dev/null
        sudo install -m 755 flannel /opt/cni/bin/flannel
        cd ~
        rm -rf /tmp/cni-plugin
    ' || {
        print_warning "Flannel CNI plugin build failed, trying alternative download..."
        sudo wget -O /opt/cni/bin/flannel https://github.com/flannel-io/cni-plugin/releases/download/v1.4.1-flannel1/flannel-riscv64 2>/dev/null
    }
fi
print_success "CNI plugins installed to /opt/cni/bin"

print_step_footer "success"

# ============================================
# Step 6: Initialize Control Plane
# ============================================

print_step_header "6" "Initializing Kubernetes control plane"

print_warning "This may take a few minutes..."

# Create kubeadm config to use local images
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 0.0.0.0
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
imageRepository: registry.k8s.io
EOF

(
    sudo kubeadm init --config /tmp/kubeadm-config.yaml -v 5 > /tmp/kubeadm_init.log 2>&1
    
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
) &
spinner $! "Initializing control plane"

# Check if init was successful
if [ -f $HOME/.kube/config ]; then
    print_success "kubeconfig created"
else
    print_error "kubeadm init may have failed. Check /tmp/kubeadm_init.log"
    echo -e "${DIM}${GRAY}$(tail -20 /tmp/kubeadm_init.log)${NC}"
    exit 1
fi

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

print_info "Preparing Flannel image..."
# 确保 Flannel 镜像存在
FLANNEL_SOURCE="docker.io/${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"
FLANNEL_TARGET="docker.io/${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"

if ! sudo ctr -n k8s.io images check "name==${FLANNEL_SOURCE}" > /dev/null 2>&1; then
    print_error "Flannel image not found. Please ensure ${FLANNEL_SOURCE} is available."
    exit 1
fi

print_info "Creating kube-flannel namespace..."
kubectl create namespace kube-flannel 2>/dev/null || true
kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged > /dev/null 2>&1 || true

cat <<EOF > /tmp/flannel-values.yaml
podCidr: "10.244.0.0/16"
image:
  repository: ${DOCKERHUB_USER}/flannel
  tag: ${FLANNEL_VERSION}
flannel:
  backend: "vxlan"
EOF

run_with_spinner "Adding Flannel Helm repo" bash -c "
    helm repo add flannel https://flannel-io.github.io/flannel/ > /dev/null 2>&1 || true
    helm repo update > /dev/null 2>&1 || true
"

print_info "Installing Flannel (this may take a moment)..."
(
    helm install flannel \
      --namespace kube-flannel \
      --values /tmp/flannel-values.yaml \
      flannel/flannel > /dev/null 2>&1
) &
spinner $! "Installing Flannel"

print_step_footer "success"

# ============================================
# Step 10: Wait for cluster to stabilize
# ============================================

print_step_header "10" "Waiting for cluster to stabilize"

print_info "Waiting for CoreDNS pods..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s 2>/dev/null || true

print_info "Waiting for Flannel pods..."
timeout=180
elapsed=0
while ! kubectl wait --for=condition=ready pod -l app=flannel -n kube-flannel --timeout=5s > /dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        print_warning "Flannel pods took longer than expected"
        break
    fi
    printf "\r${CYAN}  ${SPINNER_FRAMES[$((elapsed % ${#SPINNER_FRAMES[@]}))]}${NC} Waiting... ${elapsed}s/${timeout}s"
    sleep 2
    elapsed=$((elapsed + 2))
done
printf "\r${GREEN}  ✓${NC} Flannel pods ready\n"

print_step_footer "success"

# ============================================
# Step 11: Verify Installation
# ============================================

print_step_header "11" "Verifying installation"

sleep 5

print_info "Waiting for all nodes to be ready..."
kubectl wait --for=condition=ready node --all --timeout=60s > /dev/null 2>&1 || true

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

# Fix flannel subnet.env if needed
if [ -f /run/flannel/subnet.env ]; then
    print_success "Flannel subnet.env found"
else
    print_info "Creating flannel subnet.env..."
    sudo mkdir -p /run/flannel
    cat <<EOF | sudo tee /run/flannel/subnet.env > /dev/null
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
EOF
    print_success "flannel subnet.env created"
fi

echo ""
echo -e "${BOLD}${CYAN}Join Worker Nodes:${NC}"
echo -e "${GRAY}Run this command on worker nodes:${NC}"
echo ""
JOIN_CMD=$(sudo kubeadm token create --print-join-command 2>/dev/null | tr -d '\n' || echo "Unable to generate join command")
echo -e "${WHITE}  ${JOIN_CMD}${NC}"
echo ""

echo -e "${BOLD}${CYAN}Useful Commands:${NC}"
echo -e "${GRAY}  kubectl get nodes                              ${NC}# Check node status"
echo -e "${GRAY}  kubectl get pods -A                            ${NC}# Check all pods"
echo -e "${GRAY}  kubectl logs -n kube-flannel -l app=flannel    ${NC}# View Flannel logs"
echo -e "${GRAY}  sudo journalctl -u kubelet -f                  ${NC}# View kubelet logs"
echo ""

echo -e "${DIM}${GRAY}Setup completed at $(date)${NC}"
echo ""

rm -f /tmp/kubeadm-config.yaml /tmp/flannel-values.yaml
