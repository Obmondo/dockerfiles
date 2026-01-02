FROM ubuntu:jammy
LABEL maintainer="Anantharam R U anantharam@obmondo.com"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update     \
    && apt-get install --no-install-recommends -y \
        apt-utils \
        ca-certificates \
        lsb-release \
        pigz \
        python3-pip \
        python3-setuptools \
        curl \
        jq \
        gnupg \
        gcc \
        libffi-dev \
    && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && pip3 install --upgrade pip \
    && pip3 install --no-cache-dir awscli --upgrade \
    && pip3 install --no-cache-dir gsutil --upgrade \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        mariadb-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY ./* ./

ENTRYPOINT ["/dump.sh"]
