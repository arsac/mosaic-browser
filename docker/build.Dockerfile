# Builder image: the environment cuttle builds its x64 binary in (ubuntu:24.04,
# no sysroot, so the binary links against these libraries), plus Chromium's own
# install-build-deps for the pinned version, baked in because every chained
# build job starts a fresh container from this image.
# Adapted from glim-sh/cuttle packages/browser/build/Dockerfile.linux (MIT).
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

ARG CHROMIUM_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    DEPOT_TOOLS_UPDATE=0 \
    DEPOT_TOOLS_METRICS=0 \
    GOPATH=/tmp/go \
    GOCACHE=/tmp/go-build-cache

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git python3 python3-pip python3-venv \
    python3-httplib2 python3-six lsb-release \
    ninja-build generate-ninja clang lld llvm \
    build-essential pkg-config libgbm-dev \
    libnss3-dev \
    libxss1 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64 \
    libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    libgtk-3-0t64 libpangocairo-1.0-0 libcups2t64 \
    libdrm2 libxkbcommon0 \
    libxkbcommon-dev libpci-dev libgtk-3-dev libdrm-dev \
    libegl1-mesa-dev libgles2-mesa-dev libwayland-dev \
    libpulse-dev libxml2-dev libxslt1-dev libnotify-dev \
    libcap-dev libudev-dev libgcrypt20-dev libdbus-1-dev \
    libsystemd-dev libssl-dev libnss3 libatspi2.0-dev \
    libcurl4-openssl-dev libdouble-conversion-dev \
    libffi-dev libfontconfig1-dev libfreetype-dev \
    libglib2.0-dev libharfbuzz-dev libicu-dev \
    libjpeg-dev libjsoncpp-dev liblcms2-dev libopus-dev \
    libpng-dev libreadline-dev libsqlite3-dev libwebp-dev \
    libxcursor-dev libx11-xcb-dev libxext-dev libxfixes-dev libxi-dev \
    libxinerama-dev libxkbfile-dev libxrandr-dev libxrender-dev \
    libxshmfence-dev libxslt1-dev libxss-dev libxtst-dev \
    libz3-dev mesa-common-dev uuid-dev \
    bison flex gperf \
    xz-utils zstd zip unzip \
    rsync file sudo \
    && rm -rf /var/lib/apt/lists/*

# The script is self-contained (two stdlib-only files), so it is taken from
# Chromium's own mirror at the pinned version rather than from the build tree,
# which does not exist yet when this image is built.
RUN test -n "${CHROMIUM_VERSION}" \
    && mkdir -p /tmp/ibd \
    && for f in install-build-deps.sh install-build-deps.py; do \
         curl -fsSL -o "/tmp/ibd/$f" "https://raw.githubusercontent.com/chromium/chromium/${CHROMIUM_VERSION}/build/$f"; \
       done \
    && chmod +x /tmp/ibd/* \
    && apt-get update \
    && /tmp/ibd/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-nacl --no-arm \
    && rm -rf /tmp/ibd /var/lib/apt/lists/*

# depot_tools' metrics opt-out, for whichever uid the container runs as.
COPY --chmod=644 metrics.cfg /etc/depot_tools-metrics.cfg
RUN mkdir -p /.config/depot_tools && chmod 777 /.config /.config/depot_tools \
    && cp /etc/depot_tools-metrics.cfg /.config/depot_tools/metrics.cfg \
    && chmod 666 /.config/depot_tools/metrics.cfg

WORKDIR /repo
