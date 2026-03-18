FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NIX_INSTALLER_NO_CONFIRM=1

RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    dbus-x11 \
    git \
    gnupg \
    libasound2t64 \
    libatspi2.0-0 \
    libcanberra-gtk3-module \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnotify4 \
    libnss3 \
    libsecret-1-0 \
    libx11-xcb1 \
    libxkbfile1 \
    libxss1 \
    libxtst6 \
    mesa-utils \
    procps \
    rsync \
    software-properties-common \
    sudo \
    wget \
    xauth \
    xdg-utils \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN wget -O /tmp/code.deb "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" \
 && apt-get update \
 && apt-get install -y /tmp/code.deb \
 && rm -f /tmp/code.deb \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash dev

RUN mkdir -p /sandbox-home /workspace /nix \
 && chown -R dev:dev /sandbox-home /workspace /nix \
 && chmod 0777 /sandbox-home /workspace /nix

USER dev
WORKDIR /home/dev

RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

USER root

# Point directly at the actual store binaries, not at /home/dev/.nix-profile.
RUN NIX_BIN="$(readlink -f /home/dev/.nix-profile/bin/nix)" && \
    NIX_ENV_BIN="$(readlink -f /home/dev/.nix-profile/bin/nix-env)" && \
    NIX_STORE_BIN="$(readlink -f /home/dev/.nix-profile/bin/nix-store)" && \
    NIX_SHELL_BIN="$(readlink -f /home/dev/.nix-profile/bin/nix-shell)" && \
    NIX_INSTANTIATE_BIN="$(readlink -f /home/dev/.nix-profile/bin/nix-instantiate)" && \
    ln -sf "$NIX_BIN" /usr/local/bin/nix && \
    ln -sf "$NIX_ENV_BIN" /usr/local/bin/nix-env && \
    ln -sf "$NIX_STORE_BIN" /usr/local/bin/nix-store && \
    ln -sf "$NIX_SHELL_BIN" /usr/local/bin/nix-shell && \
    ln -sf "$NIX_INSTANTIATE_BIN" /usr/local/bin/nix-instantiate

# Clean seed for first-run /nix volume initialization.
RUN mkdir -p /nix-seed \
 && rsync -a \
      --exclude='/var/nix/gc.lock' \
      --exclude='/var/nix/db/big-lock' \
      --exclude='/var/nix/db/reserved' \
      --exclude='/var/nix/temproots/***' \
      --exclude='/var/nix/userpool/***' \
      --exclude='/var/nix/daemon-socket/***' \
      /nix/ /nix-seed/ \
 && chmod -R a+rX /nix-seed

ENV PATH=/usr/local/bin:/usr/bin:/bin

COPY container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
RUN chmod +x /usr/local/bin/container-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]