FROM k8s-ubuntu:22.04
# 设置工作目录
WORKDIR /usr/local/bin

# 复制编译好的 etcd 和 etcdctl 二进制文件
COPY etcd etcdctl .

# 添加必要的依赖
RUN apt-get update && apt-get install -y \
       ca-certificates \
       && rm -rf /var/lib/apt/lists/*

# 暴露 etcd 默认端口
EXPOSE 2379 2380

# 启动命令
ENTRYPOINT ["/usr/local/bin/etcd"]
