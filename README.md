# k8s-linux-riscv64
Deploy k8s on linux-riscv64 在linux-riscv64 上部署k8s
# 步骤

1. 下载k8s 源码，切换到1.26.5 分支，进行源码编译
2. 编辑每一个组件的Dockerfile并且 将编译后的二进制拷贝到对应目录进行docker build
3. 将每个组件docker 镜像进行上传到每一个node 或者私服，node 节点不需要全部的镜像，kube-proxy pause 和网络插件镜像就可以
4. 将k8s文件上传到 /usr/local/bin 目录下,如果能yum 或者apt 安装 则不需要上传，上传后执行kubeadm version 确认版本是否正确
5. 执行 kubeadm init  --kubernetes-version 1.26.5 --ignore-preflight-errors SystemVerification,KubeletVersion --pod-network-cidr=10.244.0.0/16  --v=6
6. 编译flannel 镜像，并且上传到每个节点，执行 kubectl apply -f kube-flannel.yml
7. 重新获取加入节点token : kubeadm token create --print-join-command

# 说明

## 版本 

docker.io/flannel/flannel                v0.21.4     
docker.io/flannel/flannel-cni-plugin     v1.1.2      
registry.k8s.io/pause                    riscv64     
registry.k8s.io/coredns/coredns          v1.9.3      
registry.k8s.io/etcd                     3.5.6-0     
registry.k8s.io/kube-proxy               v1.26.5     
registry.k8s.io/kube-controller-manager  v1.26.5     
registry.k8s.io/kube-scheduler           v1.26.5     
registry.k8s.io/kube-apiserve            v1.26.5     
registry.k8s.io/kube-apiserver           v1.26.5     
registry.k8s.io/pause                    3.9         
localhost/k8s-ubuntu                     22.04       

## k8s-ubuntu 

是一个基于riscv/ubuntu:22.04 的自定义docker image ,没多大改动

## 二进制

已经编译好的放在了release




