#!/bin/bash
# 完全修复 runc 版本问题

echo "========================================="
echo "修复 runc 版本（1.1.7 → 1.2.0）"
echo "========================================="

# 1. 查找所有 runc 位置
echo ""
echo "查找所有 runc..."
sudo find / -name runc -type f 2>/dev/null

# 2. 下载 runc 1.2.0
echo ""
echo "下载 runc 1.2.0..."
cd /tmp
rm -f runc.riscv64*

# 尝试多个下载源
for url in \
    "https://github.com/opencontainers/runc/releases/download/v1.2.0/runc.riscv64" \
    "https://ghproxy.com/https://github.com/opencontainers/runc/releases/download/v1.2.0/runc.riscv64"; do
    
    echo "尝试: $url"
    if wget -q --timeout=30 "$url" -O runc.riscv64 2>/dev/null; then
        echo "下载成功"
        break
    fi
done

if [ ! -f runc.riscv64 ]; then
    echo "下载失败，尝试系统更新"
    sudo dnf update -y runc
    exit 1
fi

# 3. 停止服务
echo ""
echo "停止服务..."
sudo systemctl stop containerd
sudo systemctl stop kubelet 2>/dev/null || true
sleep 2

# 4. 替换所有 runc
echo ""
echo "替换 runc..."
chmod +x runc.riscv64

# 替换到所有可能的位置
for dest in /usr/sbin/runc /usr/bin/runc /usr/local/sbin/runc /usr/local/bin/runc; do
    if [ -f "$dest" ] || [ -L "$dest" ]; then
        sudo cp -f runc.riscv64 "$dest"
        echo "  已替换: $dest"
    fi
done

# 确保至少这些位置存在
sudo mkdir -p /usr/local/sbin
sudo cp -f runc.riscv64 /usr/sbin/runc
sudo cp -f runc.riscv64 /usr/local/sbin/runc

# 5. 验证
echo ""
echo "验证新版本..."
runc --version

# 6. 重启 containerd
echo ""
echo "重启 containerd..."
sudo systemctl start containerd
sleep 3

# 7. 检查状态
sudo systemctl status containerd --no-pager -l | head -10

echo ""
echo "========================================="
echo "runc 升级完成！"
echo "========================================="
echo ""
echo "现在可以重新运行 kubeadm init:"
echo "  sudo kubeadm reset -f"
echo "  sudo rm -rf /etc/kubernetes/ /var/lib/etcd/ \$HOME/.kube/"
echo "  sudo kubeadm init --config /tmp/kubeadm-config.yaml"
