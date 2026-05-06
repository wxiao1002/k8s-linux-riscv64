#!/bin/bash

# ============================================
# containerd 升级和配置脚本 (RISC-V Fedora)
# ============================================

set -e

# 配置
CONTAINERD_VERSION="1.7.23"
RUNC_VERSION="1.1.14"
PAUSE_TAG="3.10.1"
DOCKERHUB_USER="cloudv10x"

# 镜像源（用于下载）
MIRRORS=(
    "https://github.com"
    "https://ghproxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_step() {
    echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# ============================================
# 下载函数（支持多个镜像源）
# ============================================

download_file() {
    local url_path="$1"
    local output_file="$2"
    
    for mirror in "${MIRRORS[@]}"; do
        local full_url="${mirror}${url_path}"
        print_info "尝试下载: $full_url"
        
        if wget -q --show-progress --timeout=30 "$full_url" -O "$output_file" 2>/dev/null; then
            print_success "下载成功"
            return 0
        fi
    done
    
    print_error "所有镜像源下载失败"
    return 1
}

# ============================================
# Step 1: 检查当前版本
# ============================================

print_step "1. 检查当前环境"

echo ""
echo "当前 containerd 版本:"
containerd --version 2>/dev/null || echo "  未安装"

echo ""
echo "当前 runc 版本:"
runc --version 2>/dev/null | head -1 || echo "  未安装"

echo ""
echo "当前 CRI 版本:"
sudo crictl version 2>/dev/null || echo "  crictl 不可用"

# ============================================
# Step 2: 停止服务
# ============================================

print_step "2. 停止相关服务"

print_info "停止 kubelet..."
sudo systemctl stop kubelet 2>/dev/null || true

print_info "停止 containerd..."
sudo systemctl stop containerd 2>/dev/null || true

sleep 3
print_success "服务已停止"

# ============================================
# Step 3: 下载 containerd
# ============================================

print_step "3. 下载 containerd ${CONTAINERD_VERSION}"

cd /tmp

CONTAINERD_FILE="containerd-${CONTAINERD_VERSION}-linux-riscv64.tar.gz"
CONTAINERD_URL="/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-riscv64.tar.gz"

if [ -f "$CONTAINERD_FILE" ]; then
    print_success "containerd 已下载: $CONTAINERD_FILE"
else
    if ! download_file "$CONTAINERD_URL" "$CONTAINERD_FILE"; then
        print_error "containerd 下载失败"
        exit 1
    fi
fi

# ============================================
# Step 4: 下载 runc
# ============================================

print_step "4. 下载 runc ${RUNC_VERSION}"

RUNC_FILE="runc.riscv64"
RUNC_URL="/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.riscv64"

if [ -f "$RUNC_FILE" ]; then
    print_success "runc 已下载: $RUNC_FILE"
else
    if ! download_file "$RUNC_URL" "$RUNC_FILE"; then
        print_error "runc 下载失败"
        exit 1
    fi
fi

# ============================================
# Step 5: 安装 containerd
# ============================================

print_step "5. 安装 containerd"

print_info "解压 containerd..."
sudo tar -xzf "$CONTAINERD_FILE" -C /usr/local

print_info "复制文件到 /usr/bin..."
for file in containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 containerd-stress ctr; do
    if [ -f "/usr/local/bin/$file" ]; then
        sudo install -m 755 "/usr/local/bin/$file" /usr/bin/
        print_success "已安装: $file"
    fi
done

# ============================================
# Step 6: 安装 runc
# ============================================

print_step "6. 安装 runc"

sudo install -m 755 "$RUNC_FILE" /usr/local/sbin/runc
sudo cp -f /usr/local/sbin/runc /usr/sbin/runc 2>/dev/null || true

print_success "runc 已安装"

# ============================================
# Step 7: 验证新版本
# ============================================

print_step "7. 验证安装"

echo ""
containerd --version
echo ""
runc --version | head -1

# ============================================
# Step 8: 配置 containerd
# ============================================

print_step "8. 配置 containerd"

print_info "生成默认配置..."
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

print_info "启用 systemd cgroup..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
print_success "SystemdCgroup = true"

print_info "配置 sandbox (pause) 镜像..."
sudo sed -i "s|sandbox_image = \"registry.k8s.io/pause:3.8\"|sandbox_image = \"registry.k8s.io/pause:${PAUSE_TAG}\"|g" /etc/containerd/config.toml
print_success "sandbox_image = registry.k8s.io/pause:${PAUSE_TAG}"

print_info "配置 CNI 插件路径..."
sudo sed -i 's|bin_dir = .*|bin_dir = "/opt/cni/bin"|g' /etc/containerd/config.toml
print_success "CNI bin_dir = /opt/cni/bin"

print_info "配置 conf_dir（如果存在）..."
sudo sed -i 's|conf_dir = .*|conf_dir = "/etc/cni/net.d"|g' /etc/containerd/config.toml 2>/dev/null || true

# ============================================
# Step 9: 配置 pause 镜像
# ============================================

print_step "9. 配置 pause 镜像标签"

print_info "检查本地 pause 镜像..."
sudo ctr -n k8s.io images list | grep pause || echo "  未找到 pause 镜像"

print_info "为 pause 镜像创建所有需要的标签..."

# 如果本地有 pause 镜像，创建多个标签
if sudo ctr -n k8s.io images list | grep -q "${DOCKERHUB_USER}/pause"; then
    SOURCE_IMAGE="docker.io/${DOCKERHUB_USER}/pause:3.10"
    
    # 需要的标签列表
    TAGS=(
        "registry.k8s.io/pause:3.6"
        "registry.k8s.io/pause:3.8"
        "registry.k8s.io/pause:3.9"
        "registry.k8s.io/pause:3.10"
        "registry.k8s.io/pause:${PAUSE_TAG}"
    )
    
    for tag in "${TAGS[@]}"; do
        if ! sudo ctr -n k8s.io images check "name==${tag}" > /dev/null 2>&1; then
            sudo ctr -n k8s.io images tag "$SOURCE_IMAGE" "$tag" 2>/dev/null && \
                print_success "已创建: $tag" || \
                print_warning "创建失败: $tag"
        else
            print_success "已存在: $tag"
        fi
    done
else
    print_warning "未找到 cloudv10x/pause:3.10 镜像，跳过标签创建"
    print_info "启动 containerd 后需要手动拉取 pause 镜像"
fi

# ============================================
# Step 10: 启动服务
# ============================================

print_step "10. 启动 containerd"

sudo systemctl daemon-reload
sudo systemctl start containerd
sleep 3

if systemctl is-active --quiet containerd; then
    print_success "containerd 已启动"
else
    print_error "containerd 启动失败"
    sudo systemctl status containerd --no-pager -l
    exit 1
fi

# ============================================
# Step 11: 验证配置
# ============================================

print_step "11. 验证配置"

echo ""
echo "=== containerd 版本 ==="
containerd --version

echo ""
echo "=== runc 版本 ==="
runc --version | head -1

echo ""
echo "=== CRI 版本 ==="
sudo crictl version

echo ""
echo "=== sandbox 镜像配置 ==="
sudo grep sandbox_image /etc/containerd/config.toml

echo ""
echo "=== pause 镜像列表 ==="
sudo crictl images | grep pause || echo "  未找到（需要拉取）"

echo ""
echo "=== containerd 状态 ==="
sudo systemctl status containerd --no-pager -l | head -10

# ============================================
# Step 12: 设置开机自启
# ============================================

print_step "12. 设置开机自启"

sudo systemctl enable containerd 2>/dev/null || true
print_success "containerd 已设置为开机自启"

# ============================================
# 完成
# ============================================

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  containerd 升级和配置完成！${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "${BOLD}版本信息:${NC}"
echo -e "  containerd: ${GREEN}$(containerd --version | awk '{print $3}')${NC}"
echo -e "  runc:       ${GREEN}$(runc --version | head -1 | awk '{print $3}')${NC}"
echo -e "  pause:      ${GREEN}registry.k8s.io/pause:${PAUSE_TAG}${NC}"
echo ""
echo -e "${BOLD}下一步:${NC}"
echo "  运行 kubernetes 主控平面安装脚本"
echo ""
