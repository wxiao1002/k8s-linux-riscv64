#!/bin/bash

# ============================================
# RISC-V K8s Image Puller (Multi-Mirror)
# 功能：多源轮询拉取 -> 自动打标到 K8s 官方名称
# ============================================

DOCKERHUB_USER="cloudv10x"
K8S_VERSION="1.35.0"
PAUSE_VERSION="3.10"
TARGET_PAUSE="3.10.1"      # K8s 1.35.0 要求的 pause 版本
ETCD_VERSION="3.6.6"
COREDNS_VERSION="1.14.0"

# 定义待下载的原始镜像列表（注意：kube-* 组件不带 v 前缀）
IMAGES=(
    "${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
    "${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"
    "${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"
    "${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"
    "${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"
)

# K8s 官方要求的镜像名称映射
declare -A K8S_IMAGE_MAP=(
    ["${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"]="registry.k8s.io/pause:${TARGET_PAUSE}"
    ["${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"]="registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"]="registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"]="registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"]="registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    ["${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64"]="registry.k8s.io/etcd:3.6.6-0"
    ["${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"]="registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}"
)

# 定义镜像站列表
MIRRORS=(
    "docker.1ms.run"
    "dockerpull.com"
    "dockerproxy.cn"
    "hub-mirror.c.163.com"
    "docker.io"  # 最后尝试直连
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}   RISC-V K8s Image Puller & Tagger                ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}\n"

if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 检查 containerd 是否运行
if ! $SUDO crictl version >/dev/null 2>&1; then
    echo -e "${RED}✗ Containerd is not running. Please start it first.${NC}"
    exit 1
fi

PULLED_COUNT=0
SKIPPED_COUNT=0
FAILED_IMAGES=()

for img in "${IMAGES[@]}"; do
    echo -e "\n${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Target: ${img}${NC}"
    
    k8s_target="${K8S_IMAGE_MAP[$img]}"
    
    # 1. 检查 K8s 目标镜像是否已存在
    if $SUDO crictl inspecti "$k8s_target" >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ K8s target image already exists: ${k8s_target}${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi
    
    # 2. 检查本地是否有源镜像（可能是上次拉取但未打标的）
    SOURCE_FOUND=false
    for src in "docker.io/$img" "$img" "docker.io/${DOCKERHUB_USER}/$(echo $img | cut -d/ -f2)"; do
        if $SUDO crictl inspecti "$src" >/dev/null 2>&1; then
            echo -e "${CYAN}  ✓ Found local source: ${src}${NC}"
            echo -ne "  ${CYAN}Tagging to K8s target: ${k8s_target} ... ${NC}"
            if $SUDO ctr -n k8s.io i tag "$src" "$k8s_target" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
                SOURCE_FOUND=true
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                break
            else
                echo -e "${YELLOW}Failed (may already exist)${NC}"
            fi
        fi
    done
    
    if [ "$SOURCE_FOUND" = true ]; then
        continue
    fi

    # 3. 尝试从各个镜像站拉取
    SUCCESS=false
    for mirror in "${MIRRORS[@]}"; do
        full_path="${mirror}/${img}"
        echo -e "  ${CYAN}Trying mirror: ${mirror}${NC}"
        
        # 使用 120 秒超时（大镜像可能需要更长时间）
        if $SUDO timeout 120s crictl pull "$full_path"; then
            echo -e "${GREEN}  ✓ Successfully pulled from ${mirror}${NC}"
            
            # 打标到 K8s 官方名称
            echo -ne "  ${CYAN}Tagging to K8s target: ${k8s_target} ... ${NC}"
            if $SUDO ctr -n k8s.io i tag "$full_path" "$k8s_target" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                # 可能已存在，尝试强制覆盖
                $SUDO ctr -n k8s.io i tag --force "$full_path" "$k8s_target" 2>/dev/null || true
                echo -e "${YELLOW}Already exists${NC}"
            fi
            
            # 同时保留 docker.io 前缀版本（便于后续操作）
            $SUDO ctr -n k8s.io i tag "$full_path" "docker.io/$img" 2>/dev/null || true
            
            SUCCESS=true
            PULLED_COUNT=$((PULLED_COUNT + 1))
            break
        else
            echo -e "${RED}  ✗ Failed or timeout on ${mirror}${NC}"
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}${BOLD}  ✗ CRITICAL: Could not pull ${img} from any mirror!${NC}"
        FAILED_IMAGES+=("$img")
    fi
done

# 显示最终结果
echo -e "\n${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}   Summary                                         ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${GREEN}✓ Pulled: ${PULLED_COUNT}${NC}"
echo -e "${YELLOW}○ Skipped: ${SKIPPED_COUNT}${NC}"

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${#FAILED_IMAGES[@]}${NC}"
    echo -e "\n${RED}Failed images:${NC}"
    for img in "${FAILED_IMAGES[@]}"; do
        echo -e "  - ${img}"
    done
    exit 1
fi

echo -e "\n${GREEN}${BOLD}All images are ready!${NC}"
echo -e "\n${CYAN}K8s target images in local registry:${NC}"
for img in "${IMAGES[@]}"; do
    k8s_target="${K8S_IMAGE_MAP[$img]}"
    echo -ne "  ${k8s_target} ... "
    if $SUDO crictl inspecti "$k8s_target" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
done

echo -e "\n${CYAN}All local images:${NC}"
$SUDO crictl images | grep -E "(${DOCKERHUB_USER}|registry.k8s.io)" || echo "  (none)"
