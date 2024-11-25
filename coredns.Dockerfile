# 构建阶段
FROM k8s-ubuntu:22.04 AS build

# 设置非交互式环境
ENV DEBIAN_FRONTEND=noninteractive

# 安装必要依赖
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       ca-certificates libcap2-bin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 复制二进制文件并设置能力
COPY coredns /coredns
RUN setcap cap_net_bind_service=+ep /coredns

# 最小化运行镜像
FROM k8s-ubuntu:22.04
WORKDIR /

# 从构建阶段复制文件
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /coredns /coredns

# 暴露 DNS 服务端口
EXPOSE 53 53/udp

# 切换到非 root 用户
RUN useradd -M -s /sbin/nologin coredns && chown coredns:coredns /coredns
USER coredns

# 启动
ENTRYPOINT ["/coredns"]

