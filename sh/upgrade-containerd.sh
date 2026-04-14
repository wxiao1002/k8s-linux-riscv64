#!/bin/bash

# ============================================
# Containerd Upgrade Script for RISC-V
# 升级 containerd 从 1.6.x 到 2.1.6
# ============================================

set -e

# 配置
CONTAINERD_VERSION="2.1.6"
CONTAINERD_DOWNLOAD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-riscv64.tar.gz"
BACKUP_DIR="/var/lib/containerd.bak.$(date +%Y%m%d_%H%M%S)"

# 颜色定义
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
echo -e "${CYAN}${BOLD}   Containerd Upgrade to v${CONTAINERD_VERSION} (RISC-V)    ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}"

# 检测架构
ARCH=$(uname -m)
if [ "$ARCH" != "riscv64" ]; then
    echo -e "\n${RED}${BOLD}ERROR: This script is for RISC-V only!${NC}"
    echo -e "${YELLOW}Detected architecture: ${ARCH}${NC}"
    exit 1
fi

echo -e "\n${CYAN}System Information:${NC}"
echo -e "  Architecture: ${ARCH}"
echo -e "  Target Version: ${CONTAINERD_VERSION}"

# 检查当前版本
if command -v containerd &> /dev/null; then
    CURRENT_VERSION=$(containerd --version 2>/dev/null | awk '{print $3}')
    echo -e "  Current Version: ${CURRENT_VERSION}"
fi

echo ""
read -p "$(echo -e ${YELLOW}Press Enter to start upgrade...${NC})"

# ============================================
# Step 1: Stop Services
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 1] Stopping services...${NC}"

echo -ne "${YELLOW}Stopping kubelet... ${NC}"
$SUDO systemctl stop kubelet 2>/dev/null || true
echo -e "${GREEN}OK${NC}"

echo -ne "${YELLOW}Stopping containerd... ${NC}"
$SUDO systemctl stop containerd 2>/dev/null || true
echo -e "${GREEN}OK${NC}"

# 确保所有 containerd 进程已停止
sleep 2
if pgrep -x containerd > /dev/null; then
    echo -e "${YELLOW}⚠ Killing remaining containerd processes...${NC}"
    $SUDO pkill -9 containerd 2>/dev/null || true
    sleep 1
fi

echo -e "${GREEN}✓ Services stopped.${NC}"

# ============================================
# Step 2: Backup Existing Data
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 2] Backing up containerd data...${NC}"

if [ -d /var/lib/containerd ]; then
    echo -ne "${YELLOW}Backing up to ${BACKUP_DIR}... ${NC}"
    $SUDO mv /var/lib/containerd "$BACKUP_DIR"
    echo -e "${GREEN}OK${NC}"
    echo -e "${GREEN}✓ Backup saved to: ${BACKUP_DIR}${NC}"
else
    echo -e "${YELLOW}⚠ /var/lib/containerd not found, skipping backup.${NC}"
fi

# 备份配置文件
if [ -f /etc/containerd/config.toml ]; then
    echo -ne "${YELLOW}Backing up config.toml... ${NC}"
    $SUDO cp /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d_%H%M%S)
    echo -e "${GREEN}OK${NC}"
fi

# ============================================
# Step 3: Download and Install
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 3] Downloading containerd v${CONTAINERD_VERSION}...${NC}"

cd /tmp
rm -f containerd-*.tar.gz
rm -rf containerd-install
mkdir -p containerd-install
cd containerd-install

echo -e "${CYAN}Download URL: ${CONTAINERD_DOWNLOAD_URL}${NC}"

if wget --show-progress -q "${CONTAINERD_DOWNLOAD_URL}"; then
    echo -e "${GREEN}✓ Download successful${NC}"
else
    echo -e "\n${YELLOW}⚠ wget failed, trying curl...${NC}"
    if curl -L -O "${CONTAINERD_DOWNLOAD_URL}"; then
        echo -e "${GREEN}✓ Download successful${NC}"
    else
        echo -e "${RED}${BOLD}✗ Download failed!${NC}"
        exit 1
    fi
fi

echo -e "\n${BLUE}${BOLD}Installing containerd...${NC}"

# 解压并安装
echo -ne "${YELLOW}Extracting binaries... ${NC}"
$SUDO tar -xzf containerd-*.tar.gz -C /usr/local
echo -e "${GREEN}OK${NC}"

# 验证安装
if [ -f /usr/local/bin/containerd ]; then
    NEW_VERSION=$(/usr/local/bin/containerd --version 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}✓ containerd installed: ${NEW_VERSION}${NC}"
else
    echo -e "${RED}✗ Installation failed!${NC}"
    exit 1
fi

# 创建符号链接
echo -ne "${YELLOW}Creating symlinks... ${NC}"
$SUDO ln -sf /usr/local/bin/containerd /usr/bin/containerd
$SUDO ln -sf /usr/local/bin/containerd-shim /usr/bin/containerd-shim
$SUDO ln -sf /usr/local/bin/containerd-shim-runc-v1 /usr/bin/containerd-shim-runc-v1
$SUDO ln -sf /usr/local/bin/containerd-shim-runc-v2 /usr/bin/containerd-shim-runc-v2
$SUDO ln -sf /usr/local/bin/ctr /usr/bin/ctr
echo -e "${GREEN}OK${NC}"

# 清理
cd /tmp
rm -rf containerd-install

# ============================================
# Step 4: Configure containerd
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 4] Configuring containerd...${NC}"

# 创建配置目录
$SUDO mkdir -p /etc/containerd

# 生成新的默认配置
echo -ne "${YELLOW}Generating new config.toml... ${NC}"
$SUDO /usr/local/bin/containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
echo -e "${GREEN}OK${NC}"

# 启用 systemd cgroup 驱动
echo -ne "${YELLOW}Enabling systemd cgroup driver... ${NC}"
$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
echo -e "${GREEN}OK${NC}"

# 配置 pause 镜像
echo -ne "${YELLOW}Configuring pause image... ${NC}"
$SUDO sed -i 's|sandbox_image = .*|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
echo -e "${GREEN}OK${NC}"

# ============================================
# Step 5: Setup systemd service
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 5] Setting up systemd service...${NC}"

# 创建 systemd 服务文件
$SUDO tee /etc/systemd/system/containerd.service > /dev/null <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
echo -e "${GREEN}✓ Service file created${NC}"

# ============================================
# Step 6: Start and Verify
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 6] Starting containerd...${NC}"

echo -ne "${YELLOW}Starting containerd... ${NC}"
$SUDO systemctl start containerd
sleep 3

if systemctl is-active --quiet containerd; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}Failed${NC}"
    echo -e "\n${YELLOW}Checking service status:${NC}"
    $SUDO systemctl status containerd --no-pager -l
    exit 1
fi

echo -ne "${YELLOW}Enabling containerd on boot... ${NC}"
$SUDO systemctl enable containerd >/dev/null 2>&1 || true
echo -e "${GREEN}OK${NC}"

# 等待 containerd 完全就绪
echo -ne "${YELLOW}Waiting for containerd socket... ${NC}"
for i in {1..10}; do
    if $SUDO crictl version >/dev/null 2>&1; then
        echo -e "${GREEN}Ready!${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 10 ]; then
        echo -e "${RED}Timeout${NC}"
        echo -e "${YELLOW}Check containerd status: sudo systemctl status containerd${NC}"
        exit 1
    fi
done

# ============================================
# Step 7: Verify installation
# ============================================

echo -e "\n${BLUE}${BOLD}[Step 7] Verifying installation...${NC}"

echo -e "\n${CYAN}Containerd version:${NC}"
containerd --version

echo -e "\n${CYAN}Service status:${NC}"
$SUDO systemctl status containerd --no-pager -l | head -5

echo -e "\n${CYAN}CRI status:${NC}"
$SUDO crictl version

# ============================================
# Summary
# ============================================

echo -e "\n${CYAN}${BOLD}====================================================${NC}"
echo -e "${GREEN}${BOLD}✓ Containerd upgrade complete!${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}\n"

echo -e "${BOLD}Version Information:${NC}"
echo -e "  Old version: ${CURRENT_VERSION:-unknown}"
echo -e "  New version: ${CONTAINERD_VERSION}"
echo ""

echo -e "${YELLOW}${BOLD}Important Notes:${NC}"
echo -e "  1. Old data backed up to: ${BACKUP_DIR}"
echo -e "  2. You may need to re-pull Kubernetes images"
echo -e "  3. Run: ${CYAN}./pull-images.sh${NC} to re-pull images"
echo ""

echo -e "${BOLD}Next Steps:${NC}"
echo -e "  1. Re-pull images: ${CYAN}./pull-images.sh${NC}"
echo -e "  2. Run control plane setup: ${CYAN}./setup-control-plane.sh${NC}"
echo ""

echo -e "${YELLOW}To restore old version if needed:${NC}"
echo -e "  sudo systemctl stop containerd"
echo -e "  sudo rm -rf /var/lib/containerd"
echo -e "  sudo mv ${BACKUP_DIR} /var/lib/containerd"
echo -e "  # Reinstall old containerd version"
echo -e "  sudo systemctl start containerd"
echo ""

echo -e "${DIM}${GRAY}Upgrade completed at $(date)${NC}\n"
