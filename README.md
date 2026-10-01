# dnsdist-distroless

A distroless container image for dnsdist, the PowerDNS load balancer / DNS proxy, built with DNS-over-TLS/HTTPS/QUIC/HTTP3 and DNSCrypt support.

## Purpose & Warning

This is a **hobby / learning project**. It is **not intended for production use** — it lacks typical hardening, monitoring, and operational features you would expect from a production-grade DNS load balancer deployment. Use at your own risk.

This project is **not affiliated with, endorsed by, or associated with PowerDNS.com B.V.** in any form. "dnsdist" and "PowerDNS" are trademarks of PowerDNS.com B.V.; this image simply compiles and packages the official, publicly available dnsdist source releases.

## Contents

- Minimal Docker build for dnsdist
  - Compiled with DNS-over-TLS, DNS-over-HTTPS, DNS-over-QUIC, DNS-over-HTTP/3, DNSCrypt, dnstap, and YAML config support
  - QUIC/HTTP3 support comes from `quiche`, pulled from a dedicated pre-built registry image (`pdns-util-quiche`) pinned by SHA256 digest
  - dnsdist tarballs are verified against official PGP signatures before building
- Final runtime image is based on `gcr.io/distroless/base-debian13` — no shell, no package manager
- Runs as a non-root user (UID/GID 1000)
- Includes an embedded `dns-healthcheck` binary for container health checks
- `Debug.Dockerfile` variant available (Debian 13-slim with bash) for interactive troubleshooting

## Quickstart

### Build

The project ships a `Makefile` that wraps the `docker buildx` invocations (reads the version from `VERSION`, sets labels, tags, etc.):

```bash
# Show all available targets
make help

# Build production image
make build-prod

# Build debug image
make build-debug

# Build both
make build
```

### Running

`make build-prod` tags the image as `registry.gitlab.com/joern_schonhoff/dnsdist-distroless:<version>` (override with `CI_REGISTRY_IMAGE=<name> make build-prod` for a local-only tag).

```bash
docker run --rm -v /path/to/dnsdist.yml:/etc/dnsdist/dnsdist.yml:ro \
  -p 53:53/udp -p 53:53/tcp \
  registry.gitlab.com/joern_schonhoff/dnsdist-distroless:$(cat VERSION)
```

Note: Runtime configuration (volumes, environment variables, networks) depends on your setup. Use the `example/` directory's Docker Compose sample as a starting point.

The debug image has no entrypoint that runs dnsdist automatically — its `CMD` sleeps forever so you can `exec` into the container and start dnsdist manually:

```bash
docker exec <container-id> /usr/bin/dnsdist -C /etc/dnsdist/dnsdist.yml
```

## Examples

The `example/` directory contains a Docker Compose setup and a sample `dnsdist.yml`.

```bash
cd example
docker compose up
```

`example/dnsdist.yml` shows a minimal configuration with two upstream backends and a UDP/TCP bind on port 53.

**Warning:** The example configuration uses an open ACL (`0.0.0.0/0`). Restrict this to private/trusted ranges before exposing the container to any untrusted network — an open ACL on a public DNS resolver/proxy can be abused as a DNS amplification vector.

## Configuration

dnsdist is compiled with `--enable-yaml`, so configuration is written in YAML rather than Lua. The default configuration path is `/etc/dnsdist/dnsdist.yml`. See `example/dnsdist.yml` for a working example covering ACLs, backends, and binds.

## Version Management

The dnsdist version is stored in the `VERSION` file. When a new version is released:

1. Update the `VERSION` file with the new version number
2. Build and test the image: `make build && make verify`
3. Commit the change

**Automated Updates:** The project is configured for Renovate bot, which will:
- Monitor https://downloads.powerdns.com/releases/ for new dnsdist releases
- Automatically create PRs when new stable versions are detected
- Also track new releases of the `pdns-util-quiche` dependency
- Extract the version number and update the `VERSION` file
- Auto-merge is disabled — all updates require manual review

## Health Checks

The production image includes an embedded DNS health check utility (`dns-healthcheck`), wired up via `HEALTHCHECK` in the Dockerfile.

**Docker Compose:**
```yaml
services:
  dnsdist:
    # ... other config ...
    healthcheck:
      test: ["CMD", "/usr/bin/dns-healthcheck", "--check-udp", "--check-tcp"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
```

**Kubernetes:**
```yaml
livenessProbe:
  tcpSocket:
    port: 53
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  tcpSocket:
    port: 53
  initialDelaySeconds: 5
  periodSeconds: 5
```

## License

GPL-2.0 (GNU General Public License v2)

This project bundles dnsdist, which is licensed under GPL-2.0. See the LICENSE file for the full text.
