
FROM k8s-ubuntu:22.04 
LABEL maintainers="Kubernetes Authors"
LABEL description="NFS subdir external provisioner"
ARG binary=./bin/nfs-subdir-external-provisioner

COPY ${binary} /nfs-subdir-external-provisioner
ENTRYPOINT ["/nfs-subdir-external-provisioner"]
