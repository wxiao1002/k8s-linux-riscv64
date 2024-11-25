FROM k8s-ubuntu:22.04
# 设置工作目录
WORKDIR /usr/local/bin

# 复制编译好的二进制文件
COPY kube-apiserver .

# 添加必要的依赖工具
RUN apt-get update && apt-get install -y \
    ca-certificates \
    iproute2 \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# 暴露 kube-apiserver 的默认端口
EXPOSE 6443

# 启动命令
ENTRYPOINT ["/usr/local/bin/kube-apiserver"]
