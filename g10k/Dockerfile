FROM ubuntu:24.04

ENV G10K_VERSION=0.9.10

RUN apt-get update \
    && apt-get install -y curl unzip git rsync \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://github.com/xorpaul/g10k/releases/download/v${G10K_VERSION}/g10k-linux-amd64.zip -o g10k-linux-amd64.zip \
    && unzip g10k-linux-amd64.zip \
    && mv g10k /usr/local/bin \
    && chmod +x /usr/local/bin/g10k \
    && rm g10k-linux-amd64.zip

RUN mkdir ~/.ssh

RUN groupadd -g 999 puppet && \
    useradd -u 999 -g 999 -m -s /bin/bash puppet

USER puppet

WORKDIR /home/puppet

ENTRYPOINT ["/bin/bash", "-c"]
