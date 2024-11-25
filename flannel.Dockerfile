FROM k8s-ubuntu:22.04

# 安装依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 \
    iptables \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 设置二进制文件目录
WORKDIR /opt/bin

# 将编译好的 flanneld 文件复制到镜像中
COPY flanneld /opt/bin/flanneld

# 确保二进制文件有执行权限
RUN chmod +x /opt/bin/flanneld

# 设置启动命令
ENTRYPOINT ["/opt/bin/flanneld"]
