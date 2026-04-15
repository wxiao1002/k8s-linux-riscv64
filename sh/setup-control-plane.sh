#!/bin/bash

# ============================================
# Kubernetes Control Plane Setup for RISC-V
# ============================================

# Configuration
K8S_VERSION="1.35.0"
TARGET_PAUSE="3.10.1"
COREDNS_VERSION="1.14.0"

set -e

# Styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

clear
echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}   Kubernetes RISC-V Control Plane Setup (v1.35.0)  ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}"

# --- Step 1: Binaries ---
echo -e "\n${BLUE}${BOLD}[Step 1] Checking Kubernetes Binaries...${NC}"
if [ ! -f /usr/local/bin/kubelet ]; then
    echo -e "${RED}✗ Kubelet not found in /usr/local/bin/${NC}"
    exit 1
fi

# 创建符号链接，确保系统能找到正确的二进制
if [ ! -f /usr/bin/kubelet ] || [ "$(readlink -f /usr/bin/kubelet 2>/dev/null)" != "/usr/local/bin/kubelet" ]; then
    echo -ne "${YELLOW}Creating symlink for kubelet... ${NC}"
    $SUDO ln -sf /usr/local/bin/kubelet /usr/bin/kubelet
    $SUDO ln -sf /usr/local/bin/kubeadm /usr/bin/kubeadm
    $SUDO ln -sf /usr/local/bin/kubectl /usr/bin/kubectl
    echo -e "${GREEN}OK${NC}"
fi

echo -e "${GREEN}✓ Binaries OK${NC}"

# --- Step 2: Cleanup ---
echo -e "\n${BLUE}${BOLD}[Step 2] Cleaning up existing configuration...${NC}"

# 停止服务
$SUDO systemctl stop kubelet 2>/dev/null || true
$SUDO systemctl stop containerd 2>/dev/null || true

# 重置 kubeadm
$SUDO kubeadm reset -f >/dev/null 2>&1 || true

# 清理旧的 kubelet 服务文件
$SUDO rm -f /usr/lib/systemd/system/kubelet.service 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/kubelet.service 2>/dev/null || true
$SUDO rm -rf /etc/systemd/system/kubelet.service.d 2>/dev/null || true
$SUDO rm -rf /usr/lib/systemd/system/kubelet.service.d 2>/dev/null || true

# 只删除 Kubernetes 相关的目录和文件
$SUDO rm -rf /etc/kubernetes/ 2>/dev/null || true
$SUDO rm -rf /var/lib/kubelet/ 2>/dev/null || true
$SUDO rm -rf /var/lib/etcd/ 2>/dev/null || true
$SUDO rm -rf $HOME/.kube/ 2>/dev/null || true
$SUDO rm -rf /etc/cni/net.d/* 2>/dev/null || true
$SUDO rm -rf /var/lib/cni/ 2>/dev/null || true

# 清理网络接口
$SUDO ip link delete cni0 2>/dev/null || true
$SUDO ip link delete flannel.1 2>/dev/null || true
$SUDO ip link delete weave 2>/dev/null || true
$SUDO ip link delete docker0 2>/dev/null || true

# 清理 iptables 规则
$SUDO iptables -F 2>/dev/null || true
$SUDO iptables -t nat -F 2>/dev/null || true
$SUDO iptables -t mangle -F 2>/dev/null || true
$SUDO iptables -X 2>/dev/null || true

$SUDO systemctl daemon-reload
echo -e "${GREEN}✓ Cleanup complete.${NC}"

# --- Step 3: Configuring Containerd ---
echo -e "\n${BLUE}${BOLD}[Step 3] Configuring Containerd...${NC}"

# 启动 containerd（如果未运行）
$SUDO systemctl start containerd 2>/dev/null || true

$SUDO mkdir -p /etc/containerd
containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
$SUDO sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:${TARGET_PAUSE}\"|" /etc/containerd/config.toml
$SUDO systemctl restart containerd

# 等待 containerd 完全就绪
echo -ne "${YELLOW}Waiting for containerd to initialize...${NC}"
MAX_RETRIES=10
COUNT=0
while ! $SUDO crictl version >/dev/null 2>&1; do
    echo -ne "."
    sleep 2
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo -e "${RED}\n✗ Containerd failed to respond within 20s.${NC}"
        exit 1
    fi
done
echo -e "${GREEN} Ready!${NC}"

# --- Step 4: Verify Required Images Exist ---
echo -e "\n${BLUE}${BOLD}[Step 4] Verifying required images are present...${NC}"

# kubeadm 需要的目标镜像
REQUIRED_IMAGES=(
    "registry.k8s.io/pause:${TARGET_PAUSE}"
    "registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    "registry.k8s.io/etcd:3.6.6-0"
    "registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}"
)

missing=false
for target_img in "${REQUIRED_IMAGES[@]}"; do
    echo -ne "${CYAN}Checking: ${target_img} ... ${NC}"
    if $SUDO crictl inspecti "$target_img" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Found${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        missing=true
    fi
done

if [ "$missing" = true ]; then
    echo -e "\n${RED}${BOLD}Missing required images!${NC}"
    echo -e "${YELLOW}Please run the image puller script first:${NC}"
    echo -e "  ${CYAN}./pull-images.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All required images are present.${NC}"

# --- Step 4.5: Pre-setup kubelet service (关键：在 init 之前) ---
echo -e "\n${BLUE}${BOLD}[Step 4.5] Pre-configuring kubelet service...${NC}"

# 创建必要的目录
$SUDO mkdir -p /var/lib/kubelet
$SUDO mkdir -p /etc/kubernetes/manifests

# 调用独立的 kubelet 配置脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/setup-kubelet.sh" ]; then
    echo -e "${CYAN}Running setup-kubelet.sh...${NC}"
    $SUDO bash "$SCRIPT_DIR/setup-kubelet.sh"
else
    echo -e "${YELLOW}⚠ setup-kubelet.sh not found, creating service manually...${NC}"
    
    # 手动创建服务
    $SUDO tee /etc/systemd/system/kubelet.service > /dev/null <<'SERVICE_EOF'
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
SERVICE_EOF

    $SUDO mkdir -p /etc/systemd/system/kubelet.service.d
    $SUDO tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf > /dev/null <<'CONF_EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
CONF_EOF

    # 创建默认配置文件（kubeadm init 会覆盖它）
    $SUDO tee /var/lib/kubelet/config.yaml > /dev/null <<'CONFIG_EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
healthzBindAddress: 127.0.0.1
healthzPort: 10248
CONFIG_EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable kubelet
fi

echo -e "${GREEN}✓ Kubelet service pre-configured.${NC}"

# --- Step 5: Initialize Kubernetes Cluster ---
echo -e "\n${BLUE}${BOLD}[Step 5] Initializing Kubernetes Cluster...${NC}"

cat <<EOF | $SUDO tee /tmp/kubeadm-config.yaml > /dev/null
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
imageRepository: registry.k8s.io
networking:
  podSubnet: 10.244.0.0/16
dns:
  imageRepository: registry.k8s.io/coredns
  imageTag: v${COREDNS_VERSION}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
EOF

$SUDO kubeadm init --config=/tmp/kubeadm-config.yaml --ignore-preflight-errors=all

# --- Step 5.5: Restart kubelet after init ---
echo -e "\n${BLUE}${BOLD}[Step 5.5] Restarting kubelet after initialization...${NC}"

$SUDO systemctl daemon-reload
$SUDO systemctl restart kubelet

# 等待 kubelet 完全就绪
echo -ne "${YELLOW}Waiting for kubelet to become healthy...${NC}"
MAX_RETRIES=30
COUNT=0
while ! curl -s http://127.0.0.1:10248/healthz >/dev/null 2>&1; do
    echo -ne "."
    sleep 2
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo -e "${RED}\n✗ Kubelet failed to become healthy within 60s.${NC}"
        echo -e "${YELLOW}Check logs: sudo journalctl -u kubelet --no-pager -n 30${NC}"
        exit 1
    fi
done
echo -e "${GREEN} Ready!${NC}"

# 配置 kubectl
mkdir -p $HOME/.kube
$SUDO cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
$SUDO chown $(id -u):$(id -g) $HOME/.kube/config

echo -e "\n${GREEN}${BOLD}====================================================${NC}"
echo -e "${GREEN}${BOLD}   SUCCESS! RISC-V Control Plane is up and running.  ${NC}"
echo -e "${GREEN}${BOLD}====================================================${NC}"

# 显示集群状态
echo -e "\n${CYAN}Cluster Info:${NC}"
kubectl cluster-info 2>/dev/null || echo -e "${YELLOW}⚠ Run 'kubectl cluster-info' after a few seconds${NC}"

echo -e "\n${CYAN}Node Status:${NC}"
kubectl get nodes 2>/dev/null || echo -e "${YELLOW}⚠ Nodes not ready yet (CNI not installed)${NC}"

echo -e "\n${YELLOW}${BOLD}Next steps:${NC}"
echo -e "  1. Install CNI plugin: ${CYAN}kubectl apply -f <cni-manifest.yaml>${NC}"
echo -e "  2. Check node status: ${CYAN}kubectl get nodes -w${NC}"
echo -e "  3. For worker nodes, use the join command below:"
echo -e "${CYAN}$(kubeadm token create --print-join-command 2>/dev/null || echo "  sudo kubeadm token create --print-join-command")${NC}"
