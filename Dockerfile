FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NIX_INSTALLER_NO_CONFIRM=1

RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    dbus-x11 \
    fd-find \
    file \
    git \
    gnupg \
    jq \
    less \
    libasound2t64 \
    libatspi2.0-0 \
    libcanberra-gtk3-module \
    libdrm2 \
    libgbm1 \
    libglib2.0-bin \
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
    ripgrep \
    software-properties-common \
    sudo \
    tree \
    unzip \
    wget \
    xauth \
    xdg-utils \
    xz-utils \
    zip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g npm@latest

RUN useradd -m -s /bin/bash dev

RUN mkdir -p /sandbox-home /workspace /nix \
    && chown -R dev:dev /sandbox-home /workspace /nix \
    && chmod 0777 /sandbox-home /workspace /nix

USER dev
WORKDIR /home/dev

RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

USER root

RUN ln -sf /home/dev/.nix-profile/bin/nix /usr/local/bin/nix && \
    [ ! -e /home/dev/.nix-profile/bin/nix-env ] || ln -sf /home/dev/.nix-profile/bin/nix-env /usr/local/bin/nix-env && \
    [ ! -e /home/dev/.nix-profile/bin/nix-store ] || ln -sf /home/dev/.nix-profile/bin/nix-store /usr/local/bin/nix-store && \
    [ ! -e /home/dev/.nix-profile/bin/nix-shell ] || ln -sf /home/dev/.nix-profile/bin/nix-shell /usr/local/bin/nix-shell && \
    [ ! -e /home/dev/.nix-profile/bin/nix-instantiate ] || ln -sf /home/dev/.nix-profile/bin/nix-instantiate /usr/local/bin/nix-instantiate

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

COPY container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
COPY ai-sandbox-open-url.sh /usr/local/bin/ai-sandbox-open-url
COPY ai-sandbox-xdg-open.sh /usr/local/bin/ai-sandbox-xdg-open
COPY ai-sandbox-vscode-update.sh /usr/local/bin/ai-sandbox-vscode-update
COPY ai-sandbox-user-code.sh /usr/local/bin/ai-sandbox-user-code
COPY ai-sandbox-default-install.sh /usr/local/bin/ai-sandbox-default-install
COPY AGENTS.md /usr/local/share/ai-sandbox/default-AGENTS.md

RUN chmod +x \
    /usr/local/bin/container-entrypoint.sh \
    /usr/local/bin/ai-sandbox-open-url \
    /usr/local/bin/ai-sandbox-xdg-open \
    /usr/local/bin/ai-sandbox-vscode-update \
    /usr/local/bin/ai-sandbox-user-code \
    /usr/local/bin/ai-sandbox-default-install \
    && ln -sf /usr/local/bin/ai-sandbox-xdg-open /usr/local/bin/xdg-open \
    && ln -sf /usr/local/bin/ai-sandbox-xdg-open /usr/bin/xdg-open \
    && ln -sf /usr/local/bin/ai-sandbox-user-code /usr/local/bin/code

ENV PATH=/usr/local/bin:/usr/bin:/bin

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]