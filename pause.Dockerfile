FROM k8s-ubuntu:22.04
ADD pause /pause
USER 65535:65535
ENTRYPOINT ["/pause"]
