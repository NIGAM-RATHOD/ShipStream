# Jenkins controller with everything the ShipStream pipeline shells out to:
# docker CLI (talks to the host daemon via the mounted socket), kubectl, helm,
# trivy, python3 (flake8/pytest), jq, and the AWS CLI for "AWS mode".
FROM jenkins/jenkins:lts-jdk21

USER root

ARG KUBECTL_VERSION=v1.37.1
ARG HELM_VERSION=v3.22.0
ARG TRIVY_VERSION=0.74.0
# Set automatically by BuildKit; amd64 or arm64.
ARG TARGETARCH=amd64

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq git unzip gosu python3 python3-venv python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI + buildx only (no daemon - we use the host's via /var/run/docker.sock).
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# kubectl (checksum-verified)
RUN curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /tmp/kubectl" | sha256sum -c - \
 && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl

# helm (checksum-verified)
RUN cd /tmp \
 && curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && echo "$(curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" | awk '{print $1}')  helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | sha256sum -c - \
 && tar -xzf "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && install -m 0755 "linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && rm -rf /tmp/helm-* "/tmp/linux-${TARGETARCH}"

# trivy (checksum-verified against the release's checksums file; pinned, bump deliberately)
RUN cd /tmp \
 && case "${TARGETARCH}" in amd64) T=Linux-64bit ;; arm64) T=Linux-ARM64 ;; *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; esac \
 && F="trivy_${TRIVY_VERSION}_${T}.tar.gz" \
 && curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${F}" \
 && curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt" | grep " ${F}\$" | sha256sum -c - \
 && tar -xzf "${F}" trivy \
 && install -m 0755 trivy /usr/local/bin/trivy \
 && rm -f trivy "${F}"

# AWS CLI v2 (only used when the pipeline runs with DEPLOY_TARGET=aws)
RUN cd /tmp \
 && case "${TARGETARCH}" in amd64) A=x86_64 ;; arm64) A=aarch64 ;; esac \
 && curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${A}.zip" \
 && unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip

# The repo is bind-mounted from the host with a different owner; let git read it.
RUN git config --system --add safe.directory '*'

# Plugins are baked into the image so a fresh jenkins_home starts fully configured.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY entrypoint.sh /usr/local/bin/shipstream-entrypoint.sh
RUN chmod 0755 /usr/local/bin/shipstream-entrypoint.sh

# Starts as root only to fix docker.sock group access, then drops to "jenkins".
ENTRYPOINT ["/usr/local/bin/shipstream-entrypoint.sh"]
