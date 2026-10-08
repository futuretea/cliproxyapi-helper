# CLIProxyAPI One-Click Install and Uninstall

> English | [简体中文](README.zh-CN.md)

> **Audience**: developers or operators deploying and maintaining CLIProxyAPI. **Prerequisites**: root access to a target Ubuntu host with a public IPv4 address. **Outcome**: complete an HTTPS installation, configure remote management, run daily checks, and uninstall safely.

This repository provides two scripts for installing or uninstalling [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) on an Ubuntu systemd host:

- `install-cliproxyapi.sh`: installs the official release package, verifies SHA256 checksums, requests a Let's Encrypt IP certificate, and configures systemd auto-start plus automatic certificate renewal.
- `uninstall-cliproxyapi.sh`: supports dry runs, data-preserving uninstalls, and full cleanup.

> `203.0.113.10` in this document is an example address; replace it with the real public IPv4 of the target host before running anything.

## Important Port Notes

CLIProxyAPI serves both its API and management page on a single shared HTTPS listening port. `--management-port` sets this shared port; it is not a separate management port.

- Default port: `443`
- API example: `https://203.0.113.10/v1/models`
- Management page: `https://203.0.113.10/management.html`
- Certificate issuance and renewal: public `80/tcp`; this port cannot serve as the shared API/management port

The scripts do not configure the host firewall, cloud firewall, or security groups. Certificate issuance and renewal require public `80/tcp` reachability on the target IPv4, and nothing else may listen on local port 80.

## Requirements

- Ubuntu with systemd and `apt-get`
- root privileges
- `x86_64`, `aarch64`, or `arm64`
- A public IPv4 bound to a global network interface of the target host
- The installation port not occupied by another process
- Public `80/tcp` reachable for the Certbot standalone HTTP-01 challenge
- Access to GitHub, Ubuntu package mirrors, the Snap Store, and Let's Encrypt

The installer installs or uses the following system dependencies: `ca-certificates`, `curl`, `iproute2`, `openssl`, `python3`, `snapd`, `tar`, `util-linux`, and the Certbot snap.

## Quick Install

Run from the machine holding the scripts:

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 443 --enable-remote-management' \
  < ./install-cliproxyapi.sh
```

This command will:

1. Download the pinned default version `v8.0.20` and verify the release package against the official `checksums.txt`.
2. Create a restricted system user `cliproxy`.
3. Request a short-lived Let's Encrypt certificate containing the target IPv4 SAN.
4. Start the API and remote management page on port 443 of the target IPv4.
5. Enable `cli-proxy-api.service` and the Certbot renewal timer.
6. Verify API authentication, management authentication, and a certificate renewal dry run.

After a successful installation, visit:

```text
https://203.0.113.10/management.html
```

### Retrieve the Management Password

The management password is stored only in a root-readable environment file, and the installer never prints it:

```bash
ssh root@203.0.113.10 \
  "sed -n 's/^MANAGEMENT_PASSWORD=//p' /etc/cli-proxy-api/management.env"
```

Treat the output as a secret; never write it into scripts, logs, chats, or version control.

### Retrieve the Client API Key

The client API key lives in the `api-keys` section of `/var/lib/cli-proxy-api/config.yaml`. Handle that file as sensitive configuration; do not copy the whole file into logs or documents.

Read only the first installer-generated API key:

```bash
ssh root@203.0.113.10 \
  "sed -n '/^api-keys:/{n;s/^[[:space:]]*-[[:space:]]*//;s/^\"//;s/\"$//;p;q;}' /var/lib/cli-proxy-api/config.yaml"
```

Example API call:

```bash
curl --fail \
  -H 'Authorization: Bearer <api-key>' \
  https://203.0.113.10/v1/models
```

## Install Options

| Option | Default | Description |
|---|---:|---|
| `--ip <public-ipv4>` | required | Public IPv4 used as certificate identity and service bind address |
| `--management-port <port>` | `443` | Shared HTTPS port for the API and management page; any value `1..65535` except Certbot-reserved `80` |
| `--enable-remote-management` | off for new installs | Expose the management page and remote management API |
| `--disable-remote-management` | — | Disable the management page and remote management API |
| `--cliproxy-version <tag\|latest>` | `v8.0.20` | Install a pinned release tag, or resolve the latest GitHub release |
| `--acme-email <email>` | none | Register an email address with the Let's Encrypt account |
| `-h`, `--help` | — | Show help |

The scripts also read the `CLIPROXY_VERSION` and `ACME_EMAIL` environment variables. Final precedence: command-line options > environment variables > built-in defaults above; `ACME_EMAIL` has no built-in default.

Open an additional shared port, for example 8443:

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 8443 --enable-remote-management' \
  < ./install-cliproxyapi.sh
```

Disable remote management but keep the API:

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 443 --disable-remote-management' \
  < ./install-cliproxyapi.sh
```

### Repeated Runs and Upgrades

The installer is safe to re-run:

- With an existing managed configuration, API keys and other settings outside installer control are preserved.
- When no management flag is passed, new installs default to management off; existing managed installs keep their current all-on or all-off state.
- If `allow-remote` and `disable-control-panel` are in a mixed state, the script stops and asks for an explicit enable or disable flag.
- Install a specific version with `--cliproxy-version <tag>`; `latest` resolves the newest GitHub release at execution time.

## Daily Operations

Check service status:

```bash
ssh root@203.0.113.10 'systemctl status cli-proxy-api.service --no-pager'
```

View logs:

```bash
ssh root@203.0.113.10 'journalctl -u cli-proxy-api.service -n 100 --no-pager'
```

Check the listening port:

```bash
management_port=443
ssh root@203.0.113.10 "ss -lnt 'sport = :${management_port}'"
```

Use the actual port if you installed with a different one.

Check certificate SAN and validity:

```bash
ssh root@203.0.113.10 \
  "openssl x509 -in /etc/cli-proxy-api/tls/fullchain.pem -noout -dates -ext subjectAltName"
```

Check the renewal timer:

```bash
ssh root@203.0.113.10 \
  'systemctl status snap.certbot.renew.timer --no-pager'
```

## Files and Permissions

| Path | Purpose |
|---|---|
| `/usr/local/bin/cli-proxy-api` | CLIProxyAPI binary |
| `/etc/systemd/system/cli-proxy-api.service` | systemd service unit |
| `/var/lib/cli-proxy-api/config.yaml` | Managed configuration and client API key; `cliproxy:cliproxy`, `0600` |
| `/etc/cli-proxy-api/management.env` | Management password; `root:root`, `0600`; absent when management is disabled |
| `/etc/cli-proxy-api/tls/` | Certificate copies used by the service |
| `/var/lib/cli-proxy-api/auth/` | CLIProxyAPI authentication state directory |
| `/var/lib/cli-proxy-api/static/` | Management page static assets directory |
| `/etc/letsencrypt/renewal-hooks/deploy/50-cliproxyapi` | Post-renewal hook that copies certificates and restarts the service |

The service runs as the non-root user `cliproxy`. When listening on port 443 or another low port, systemd grants only `CAP_NET_BIND_SERVICE`.

## Uninstall

### Dry Run First

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --purge --dry-run' \
  < ./uninstall-cliproxyapi.sh
```

`--dry-run` only lists exact targets; it changes nothing on the host.

### Uninstall the Program, Keep the Data

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --yes' \
  < ./uninstall-cliproxyapi.sh
```

This mode removes the systemd service, binary, and renewal deploy hook, but keeps the configuration, credentials, state, certificates, and the `cliproxy` user for a later reinstall.

### Full Cleanup

> **Warning**: `--purge` deletes the configuration, client API key, management password, authentication state, IP certificate, and the `cliproxy` user and group. Confirm you no longer need this data before running it.

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --purge --yes' \
  < ./uninstall-cliproxyapi.sh
```

The uninstall script never removes the shared Certbot or snapd packages.

## FAQ

### Port Already in Use

The installer refuses to take over a target port used by another process. Find the occupant with `ss -lntp`, then either adjust that service or switch via `--management-port`.

### Certificate Issuance or Renewal Fails

Confirm the following:

- `--ip` matches the public IPv4 on a global network interface of the host exactly.
- Nothing is listening on local port 80.
- The cloud firewall, security groups, upstream NAT, and host firewall allow public access to `80/tcp`.
- A DNS domain is not required; this script requests an IP SAN certificate.

Check Certbot logs:

```bash
ssh root@203.0.113.10 'journalctl -u snap.certbot.renew.service --no-pager'
```

### Management Page Unreachable

Confirm the install passed `--enable-remote-management`, then check service status, the shared HTTPS port, and network access policy. A loading management page does not imply the management API passed authentication; login still requires the password in `/etc/cli-proxy-api/management.env`.

## Security Boundaries

- With remote management enabled, the management entry point is exposed on the target HTTPS port and protected by the management password.
- API keys, the management password, TLS private keys, and the authentication directory are secrets or sensitive data.
- The scripts never print generated API keys or the management password to install output.
- The scripts do not configure source restrictions, rate limits, reverse proxies, or cloud firewalls.
- Never commit real credentials, configuration files, or certificates to version control.
