FROM jenkins/jenkins:lts
USER root

RUN apt-get update && apt-get install -y curl unzip gnupg lsb-release

# Docker CLI only — builds run against the HOST's daemon via the mounted socket
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y docker-ce-cli

# AWS CLI v2 + kubectl, architecture-aware
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then AWSARCH=aarch64; KARCH=arm64; \
    else AWSARCH=x86_64; KARCH=amd64; fi && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o awscliv2.zip && \
    unzip -q awscliv2.zip && ./aws/install && rm -rf awscliv2.zip aws && \
    curl -LO "https://dl.k8s.io/release/v1.28.0/bin/linux/${KARCH}/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kubectl
RUN curl -LO "https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

USER jenkins
