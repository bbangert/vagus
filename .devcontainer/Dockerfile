FROM ubuntu:26.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    avahi-utils \
    file \
    automake \
    autoconf \
    git \
    curl \
    wget \
    unzip \
    pkg-config \
    libssl-dev \
    libncurses5-dev \
    libmnl-dev \
    protobuf-compiler \
    squashfs-tools \
    ssh-askpass \
    inotify-tools \
    libarchive-dev \
    libconfuse-dev \
    && rm -rf /var/lib/apt/lists/*

# Install fwup from GitHub releases (not in Ubuntu repos)
RUN FWUP_VERSION="1.15.0" && \
    curl -fsSL "https://github.com/fwup-home/fwup/releases/download/v${FWUP_VERSION}/fwup_${FWUP_VERSION}_amd64.deb" -o /tmp/fwup.deb && \
    dpkg -i /tmp/fwup.deb && \
    rm /tmp/fwup.deb

# Souffle is the Datalog solver `mix argus` shells out to. Its PPA package
# links against libffi7, which Ubuntu dropped after 20.04, so that build is
# installed first (checksum-pinned). Mirrors .github/workflows/ci.yml.
RUN curl -fsSLo /tmp/libffi7.deb http://archive.ubuntu.com/ubuntu/pool/main/libf/libffi/libffi7_3.3-4_amd64.deb && \
    echo "4584aa8fef1bf5086168ce2f7078cd2ebd78fdc4cc0d86d958d795d4e0b0f50d  /tmp/libffi7.deb" | sha256sum -c - && \
    curl -fsSLo /usr/share/keyrings/souffle-archive-keyring.gpg https://souffle-lang.github.io/ppa/souffle-key.public && \
    echo "deb [signed-by=/usr/share/keyrings/souffle-archive-keyring.gpg] https://souffle-lang.github.io/ppa/ubuntu/ stable main" > /etc/apt/sources.list.d/souffle.list && \
    apt-get update && apt-get install -y /tmp/libffi7.deb souffle && \
    rm -rf /tmp/libffi7.deb /var/lib/apt/lists/*

RUN id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu \
    && mkdir -p /workspaces && chown ubuntu:ubuntu /workspaces

USER ubuntu

# Install mise
RUN curl https://mise.run | sh
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

RUN mise settings set experimental true

WORKDIR /workspaces
