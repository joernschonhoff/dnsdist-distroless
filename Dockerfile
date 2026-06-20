# Global build args — defined before any FROM so they are available in all stages
ARG DISTROLESS_IMAGE=gcr.io/distroless/base-debian13@sha256:f2df8702d4dcc45ce76df6cbc14ad1975fcf88a04bd0e8947b6194264f9ab75e

# Stage 1: Build Cloudflare quiche (DoQ/DoH3/HTTP3 support)
# quiche is not packaged in Debian; must be compiled from source.
FROM rust:1.95-trixie@sha256:0861191076afc8e2dfcf0bec6ad6c2dec8494b3a1e9249729e1989690afed5ec AS quiche-builder
ARG QUICHE_VERSION
RUN test -n "${QUICHE_VERSION}" || { echo "QUICHE_VERSION build-arg is required"; exit 1; }

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
        cmake \
        clang-19 \
        git

RUN git clone --recursive --depth 1 --branch ${QUICHE_VERSION} https://github.com/cloudflare/quiche.git /src
WORKDIR /src

COPY build_quiche.sh /build_quiche.sh
RUN chmod +x /build_quiche.sh \
    && /build_quiche.sh

# Pull distroless base into a named stage so it can be referenced in COPY --from
# (ARG substitution is not supported in COPY --from, only in FROM)
FROM ${DISTROLESS_IMAGE} AS distroless

# Stage 2: Compile dnsdist with all DNS-over-* features
FROM debian:13-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8 AS builder
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

# Reuse the Rust toolchain built in stage 1 instead of downloading via curl|sh
COPY --from=quiche-builder /usr/local/cargo /usr/local/cargo
COPY --from=quiche-builder /usr/local/rustup /usr/local/rustup
ENV PATH="/usr/local/cargo/bin:${PATH}" CARGO_HOME="/usr/local/cargo" RUSTUP_HOME="/usr/local/rustup"

# Copy quiche headers, libs, and pkg-config files into the build environment
COPY --from=quiche-builder /quiche_lib/ /

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

# Stage 3: Minimal distroless runtime — no shell, no package manager
FROM ${DISTROLESS_IMAGE} AS runtime

# Re-declare build args needed in this stage (ARGs before FROM are scoped to FROM only)
ARG DNSDIST_VERSION

LABEL description="dnsdist ${DNSDIST_VERSION} on distroless Debian 13 with DoT/DoH/DoQ/HTTP3/DNSCrypt support"
LABEL license="MIT"
LABEL maintainer="Joern Schonhoff"
LABEL org.opencontainers.image.authors="Joern Schonhoff"
# LABEL org.opencontainers.image.created="FILLED BY BUILD SYSTEM"
LABEL org.opencontainers.image.description="dnsdist ${DNSDIST_VERSION} on distroless Debian 13 with DoT/DoH/DoQ/HTTP3/DNSCrypt support"
LABEL org.opencontainers.image.licenses="MIT"
# LABEL org.opencontainers.image.revision="FILLED BY BUILD SYSTEM"
LABEL org.opencontainers.image.source="https://gitlab.com/joern_schonhoff/dnsdist-distroless"
LABEL org.opencontainers.image.title="dnsdist-distroless"
LABEL org.opencontainers.image.url="https://gitlab.com/joern_schonhoff/dnsdist-distroless"
LABEL org.opencontainers.image.version="${DNSDIST_VERSION}"
LABEL version="${DNSDIST_VERSION}"

COPY --from=builder /runtime/ /
COPY --from=registry.gitlab.com/joern_schonhoff/dns-healthcheck:v0.1.0@sha256:93fc019639c0170f2cf00a49acd623009a9cd755a04a8a8527add1464683c144 /dns-healthcheck /usr/bin/dns-healthcheck

ENV TERM=dumb

EXPOSE 53/tcp 53/udp 443/tcp 853/tcp 853/udp 8443/tcp 8443/udp

USER 1000:1000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
    CMD ["/usr/bin/dns-healthcheck", "--check-udp", "--check-tcp"]

ENTRYPOINT ["/usr/bin/dnsdist"]
CMD [ "--supervised", "--disable-syslog" ]
