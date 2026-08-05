# The fly Machine image. A fly Machine is a Firecracker microVM with its own kernel,
# so it runs a real docker engine (this is not shared-kernel docker-in-docker). The
# Machine is the always-on host; it is NOT the cage. A bare microVM presents no
# container marker, so faff's gate would fail on it. The gate passes inside the nested
# cage container this Machine runs, which is where the drain actually happens.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg bash coreutils jq \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io \
 && rm -rf /var/lib/apt/lists/*

# The cage build context (Dockerfile plus the drain script it copies in) and the
# Machine entrypoint.
COPY cage/Dockerfile /cage/Dockerfile
COPY drain.sh        /cage/drain.sh
COPY entrypoint.sh   /entrypoint.sh
RUN chmod +x /entrypoint.sh /cage/drain.sh

ENTRYPOINT ["/entrypoint.sh"]
