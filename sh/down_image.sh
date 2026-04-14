#!/bin/bash

# ============================================
# RISC-V K8s Image Puller (Multi-Mirror)
# 功能：多源轮询拉取 -> 自动打标 -> 预热本地仓库
# ============================================

DOCKERHUB_USER="cloudv10x"
K8S_VERSION="1.35.0"
PAUSE_VERSION="3.10"
ETCD_VERSION="3.6.6"
COREDNS_VERSION="1.14.0"

# 定义待下载的原始镜像列表
IMAGES=(
    "${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
    "${DOCKERHUB_USER}/kube-apiserver:v${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-controller-manager:v${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-scheduler:v${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-proxy:v${K8S_VERSION}"
    "${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"
    "${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"
)

# 定义目前国内可能可用的镜像站后缀
MIRRORS=(
    "docker.1ms.run"
    "dockerpull.com"
    "dockerproxy.cn"
    "hub-mirror.c.163.com"
    "docker.io" # 最后尝试直连
)

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}Starting RISC-V Image Pre-load...${NC}\n"

if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

for img in "${IMAGES[@]}"; do
    echo -e "${YELLOW}------------------------------------------------${NC}"
    echo -e "${BOLD}Target: $img${NC}"
    
    # 1. 检查本地是否已存在（标准名）
    if $SUDO crictl inspecti "docker.io/$img" > /dev/null 2>&1 || $SUDO crictl inspecti "$img" > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Image already exists. Skipping.${NC}"
        continue
    fi

    SUCCESS=false
    for mirror in "${MIRRORS[@]}"; do
        full_path="${mirror}/${img}"
        echo -e "  Trying mirror: ${CYAN}${mirror}${NC}..."
        
        # 使用 60 秒超时防止死锁
        if $SUDO timeout 60s crictl pull "$full_path"; then
            echo -e "${GREEN}  ✓ Successfully pulled from $mirror${NC}"
            
            # 2. 如果是从镜像站拉取的，需要打回原名标签（K8s 只认 docker.io/ 或无前缀名）
            if [ "$mirror" != "docker.io" ]; then
                echo -e "  Tagging ${full_path} -> docker.io/${img}"
                $SUDO ctr -n k8s.io i tag "$full_path" "docker.io/$img" > /dev/null 2>&1
                $SUDO ctr -n k8s.io i tag "$full_path" "$img" > /dev/null 2>&1
            fi
            SUCCESS=true
            break
        else
            echo -e "${RED}  ✗ Failed or Timeout on $mirror${NC}"
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}  !!! Critical Error: Could not pull $img from any mirror.${NC}"
    fi
done

echo -e "\n${GREEN}Final Local Image List:${NC}"
$SUDO crictl images
