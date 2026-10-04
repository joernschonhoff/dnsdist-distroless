# Global build args — defined before any FROM so they are available in all stages
ARG DEBIAN_BASE_IMAGE=debian:13-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8
ARG DISTROLESS_IMAGE=gcr.io/distroless/base-debian13@sha256:f2df8702d4dcc45ce76df6cbc14ad1975fcf88a04bd0e8947b6194264f9ab75e
ARG DNS_HEALTHCHECK_IMAGE=registry.gitlab.com/joern_schonhoff/dns-healthcheck:v0.1.2@sha256:419dc6042673a0a9d0893b56821983dd656649603a3fe0175ab168ae6f04d77f
ARG QUICHE_IMAGE=registry.gitlab.com/joern_schonhoff/pdns-util-quiche:0.30.0@sha256:7394989dc4ecccda6c0bf324f44c0db82e1be9c9107e033045dace29c7b89e14
ARG RUST_IMAGE=rust:1.98.1-trixie@sha256:462a9af3c54fb4718850d3c602fc0e54452c20b1c12a4e4080fdb001d4b9acbf

# Pull distroless and quiche into named stages so they can be referenced in COPY --from
# (ARG substitution is not supported in COPY --from, only in FROM)
FROM ${DISTROLESS_IMAGE} AS distroless
FROM ${QUICHE_IMAGE} AS quiche
FROM ${DNS_HEALTHCHECK_IMAGE} AS dns-healthcheck
FROM ${RUST_IMAGE} AS rust

# Stage 1: Compile dnsdist with all DNS-over-* features
FROM ${DEBIAN_BASE_IMAGE} AS builder
ARG DNSDIST_VERSION
RUN test -n "${DNSDIST_VERSION}" || { echo "DNSDIST_VERSION build-arg is required"; exit 1; }

ENV DEBIAN_FRONTEND=noninteractive

# LuaJIT is effectively unmaintained upstream but still patched by Debian;
# kept for significantly better performance over Lua 5.4 in packet processing rules.
# Alternative: replace libluajit-5.1-dev with lua5.4-dev and --with-lua=lua in configure.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
        ca-certificates \
        clang-19 \
        curl \
        gnupg \
        g++ \
        gcc \
        libboost-context-dev \
        libboost-dev \
        libboost-filesystem-dev \
        libboost-serialization-dev \
        libboost-system-dev \
        libboost-thread-dev \
        libedit-dev \
        libfstrm-dev \
        libluajit-5.1-dev \
        libnghttp2-dev \
        libre2-dev \
        libsodium-dev \
        libssl-dev \
        lua5.4 \
        luajit \
        make \
        pkg-config \
        python3 \
        python3-yaml \
        xz-utils

# Official PowerDNS signing keys — keyblock from https://dnsdist.org/_static/dnsdist-keyblock.asc
COPY dnsdist-keyblock.asc /tmp/dnsdist-keyblock.asc

# Reuse the Rust toolchain for building dnsdist with Lua
COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV PATH="/usr/local/cargo/bin:${PATH}" CARGO_HOME="/usr/local/cargo" RUSTUP_HOME="/usr/local/rustup"

# Copy quiche library (DoQ/DoH3/HTTP3 support) from dedicated build image
COPY --from=quiche /quiche_lib/ /

WORKDIR /src

# Verify tarball against detached PGP signature before extracting
RUN gpg --import /tmp/dnsdist-keyblock.asc \
    && curl -sSL https://downloads.powerdns.com/releases/dnsdist-${DNSDIST_VERSION}.tar.xz -o dnsdist-${DNSDIST_VERSION}.tar.xz \
    && curl -sSL https://downloads.powerdns.com/releases/dnsdist-${DNSDIST_VERSION}.tar.xz.asc -o dnsdist-${DNSDIST_VERSION}.tar.xz.asc \
    && gpg --verify dnsdist-${DNSDIST_VERSION}.tar.xz.asc dnsdist-${DNSDIST_VERSION}.tar.xz \
    && tar xf dnsdist-${DNSDIST_VERSION}.tar.xz --strip-components=1

RUN ./configure \
        --disable-systemd \
        --enable-dns-over-http3 \
        --enable-dns-over-https \
        --enable-dns-over-quic \
        --enable-dns-over-tls \
        --enable-dnscrypt \
        --enable-dnstap \
        --enable-yaml \
        --libdir=/usr/lib/dnsdist \
        --localstatedir=/var \
        --mandir=/usr/share/man \
        --prefix=/usr \
        --sysconfdir=/etc/dnsdist \
        --with-boost=/usr/include \
        --with-libsodium \
        --with-libssl \
        --with-lua=luajit \
        --with-re2 \
    && make -j4 \
    && DESTDIR=/build make install \
    && strip /build/usr/bin/*

# Assemble /runtime: installed files + all required shared libraries
RUN mkdir -p /runtime \
	&& cp -a /build/* /runtime/

# Collect shared libraries via ldd; rewrite /lib/ -> /usr/lib/ because
# distroless has /lib as a symlink to usr/lib on Debian 13
RUN find /build -type f -executable -exec sh -c \
	'for f; do ldd "$f" 2>/dev/null | awk "/=>/ {print \$3}" ; done' sh {} + \
	| sort -u | grep -E "^/" \
	| while read src; do \
	    dest=$(echo "$src" | sed 's|^/lib/|/usr/lib/|'); \
	    mkdir -p "/runtime$(dirname $dest)"; \
	    cp -L "$src" "/runtime$dest"; \
	  done

# Preserve distroless base entries (root, nobody, nonroot) then append pdns
RUN mkdir -p /runtime/etc
COPY --from=distroless /etc/passwd /runtime/etc/passwd
COPY --from=distroless /etc/group /runtime/etc/group
RUN echo "pdns:x:1000:1000:PowerDNS user:/var/lib/pdns:/sbin/nologin" >> /runtime/etc/passwd \
    && echo "pdns:x:1000:" >> /runtime/etc/group

# Strip debug symbols from collected shared libraries to reduce image size
RUN find /runtime -type f \( -name "*.so" -o -name "*.so.*" \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

# Minimal terminfo entry so dnsdist console output works without a real terminal
RUN mkdir -p /runtime/usr/share/terminfo/d \
    && cp /usr/share/terminfo/d/dumb /runtime/usr/share/terminfo/d/dumb

# Stage 2: Minimal distroless runtime — no shell, no package manager
FROM ${DISTROLESS_IMAGE} AS runtime

# Re-declare build args needed in this stage (ARGs before FROM are scoped to FROM only)
ARG DNSDIST_VERSION

# SPDX identifier required by the OCI image-spec for org.opencontainers.image.licenses
LABEL \
    org.opencontainers.image.authors="Joern Schonhoff" \
    org.opencontainers.image.description="dnsdist ${DNSDIST_VERSION} on distroless Debian 13 with DoT/DoH/DoQ/HTTP3/DNSCrypt support" \
    org.opencontainers.image.licenses="GPL-2.0-only" \
    org.opencontainers.image.source="https://gitlab.com/joern_schonhoff/dnsdist-distroless" \
    org.opencontainers.image.title="dnsdist-distroless" \
    org.opencontainers.image.url="https://gitlab.com/joern_schonhoff/dnsdist-distroless" \
    org.opencontainers.image.version="${DNSDIST_VERSION}"
    #   org.opencontainers.image.created="FILLED BY BUILD SYSTEM"
    #   org.opencontainers.image.revision="FILLED BY BUILD SYSTEM"

COPY --from=builder /runtime/ /
COPY --from=dns-healthcheck /dns-healthcheck /usr/bin/dns-healthcheck

ENV TERM=dumb

EXPOSE 53/tcp 53/udp 443/tcp 853/tcp 853/udp 8443/tcp 8443/udp

USER 1000:1000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
    CMD ["/usr/bin/dns-healthcheck", "--check-udp", "--check-tcp"]

ENTRYPOINT ["/usr/bin/dnsdist"]
CMD [ "--supervised", "--disable-syslog" ]
