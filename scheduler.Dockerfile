FROM k8s-ubuntu:22.04

# 设置工作目录
WORKDIR /usr/local/bin

# 复制编译好的二进制文件
COPY kube-scheduler .

# 添加必要的依赖
RUN apt-get update && apt-get install -y \
       ca-certificates \
       && rm -rf /var/lib/apt/lists/*

# 暴露 kube-scheduler 的默认端口（可选）
EXPOSE 10251

# 启动命令
ENTRYPOINT ["/usr/local/bin/kube-scheduler"]

