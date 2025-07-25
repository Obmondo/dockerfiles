FROM ubuntu:jammy
LABEL maintainer="Divyam Azad divyam@obmondo.com"

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
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && cat /etc/apt/sources.list.d/pgdg.list \
    && curl --silent https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update \
    && apt-get install --no-install-recommends -y  \
        postgresql-client-17  \
        postgresql-client-16  \
        postgresql-client-15  \
        postgresql-client-14  \
        postgresql-client-13  \
        postgresql-client-12  \
        postgresql-client-11  \
        postgresql-client-10  \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY ./* ./

ENV PG_DIR=/usr/lib/postgresql


ENTRYPOINT ["/dump.sh"]
