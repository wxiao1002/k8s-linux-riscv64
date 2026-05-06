#!/bin/bash

# ============================================
# RISC-V K8s Image Puller 
# ============================================

DOCKERHUB_USER="cloudv10x"
K8S_VERSION="1.35.0"
PAUSE_VERSION="3.10"
TARGET_PAUSE="3.10.1"
ETCD_VERSION="3.6.6"
COREDNS_VERSION="1.14.0"

IMAGES=(
    "${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
    "${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"
    "${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"
    "${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"
)

declare -A K8S_IMAGE_MAP=(
    ["${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"]="registry.k8s.io/pause:${TARGET_PAUSE}"
    ["${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"]="registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"]="registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"]="registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"]="registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"]="registry.k8s.io/etcd:3.6.6-0"
    ["${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"]="registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}"
)

# 可用的镜像站（按优先级排序）
MIRRORS=(
    "docker.1ms.run"
    "docker.m.daocloud.io"
    "dockerhub.icu"
    "docker.rainbond.cc"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}   RISC-V K8s Image Puller (Fixed)                 ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}\n"

if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 修复 containerd 目录
echo -e "${YELLOW}Ensuring containerd directories exist...${NC}"
$SUDO mkdir -p /var/lib/containerd/io.containerd.content.v1.content/ingest
$SUDO mkdir -p /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
$SUDO systemctl restart containerd
sleep 3

# 检查 containerd
if ! $SUDO crictl version >/dev/null 2>&1; then
    echo -e "${RED}✗ Containerd is not running.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Containerd is ready${NC}\n"

PULLED=0
FAILED=()

for img in "${IMAGES[@]}"; do
    echo -e "\n${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Target: ${img}${NC}"
    
    k8s_target="${K8S_IMAGE_MAP[$img]}"
    
    # 检查是否已存在
    if $SUDO crictl inspecti "$k8s_target" >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Already exists${NC}"
        ((PULLED++))
        continue
    fi
    
    SUCCESS=false
    for mirror in "${MIRRORS[@]}"; do
        full_path="${mirror}/${img}"
        echo -ne "  ${CYAN}Trying ${mirror}... ${NC}"
        
        # 使用 ctr 拉取（有时比 crictl 更稳定）
        if $SUDO ctr -n k8s.io image pull "$full_path" 2>&1 | grep -q "unpacking"; then
            echo -e "${GREEN}✓ Pulled${NC}"
            
            # 打标
            $SUDO ctr -n k8s.io i tag "$full_path" "$k8s_target" 2>/dev/null || true
            
            SUCCESS=true
            ((PULLED++))
            break
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}${BOLD}  ✗ Failed to pull ${img}${NC}"
        FAILED+=("$img")
    fi
done

echo -e "\n${CYAN}${BOLD}====================================================${NC}"
echo -e "${GREEN}✓ Pulled: ${PULLED}${NC}"

if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${#FAILED[@]}${NC}"
    exit 1
fi

echo -e "\n${GREEN}${BOLD}All images ready!${NC}\n"
$SUDO crictl images | grep -E "(cloudv10x|registry.k8s.io)"
