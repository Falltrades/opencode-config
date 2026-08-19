# Dockerfile — extends the official opencode image (Alpine/musl) with
# git, a native musl Rust/Cargo toolchain, and rtk built from source.

FROM ghcr.io/anomalyco/opencode:1.18.13 AS build

# --- git + build toolchain for compiling rtk (and anything else) ---
# build-base / musl-dev / openssl-dev / pkgconf cover the common Rust
# native-dependency needs (openssl-sys, ring, etc.). Drop what you don't need.
RUN apk add --no-cache \
        bash \
        git \
        curl \
        ca-certificates \
        build-base \
        musl-dev \
        openssl-dev \
        pkgconf \
        python3 \
        rust \
        rustup \
        rustfmt \
        rust-clippy \
        cargo \
        nodejs \
        npm \
        strace \
        openjdk17-jre-headless

RUN apk add --no-cache rustup \
    && rustup-init -y --default-toolchain none --no-modify-path \
    && cp /root/.cargo/bin/rustup /usr/local/bin/rustup \
    && chmod 755 /usr/local/bin/rustup \
    && rm -rf /root/.cargo /root/.rustup

RUN cargo install --git https://github.com/rtk-ai/rtk --root /usr/local
RUN cargo install dioxus-cli@0.7.9 --root /usr/local --locked
RUN curl -sSLO https://github.com/pinterest/ktlint/releases/download/1.8.0/ktlint \
    && chmod a+x ktlint \
    && mv ktlint /usr/local/bin/ktlint

ARG GITLEAKS_VERSION=8.30.1
RUN curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
       -o /tmp/gitleaks.tar.gz \
    && tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks \
    && chmod +x /usr/local/bin/gitleaks \
    && rm /tmp/gitleaks.tar.gz
