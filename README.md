# VPN Stack

Auditable installer for OpenVPN, Cisco/AnyConnect, and direct VLESS/TCP on Ubuntu 22.04, 24.04 or 26.04:

| Mode | Port | Client |
| --- | --- | --- |
| OpenVPN, automatic UDP then TCP | 1194/UDP, 1195/TCP | `auto.ovpn` |
| OpenVPN UDP only | 1194/UDP | `udp.ovpn` |
| OpenVPN TCP only | 1195/TCP | `tcp.ovpn` |
| ocserv / Cisco AnyConnect | 110/TCP and 110/UDP | `https://VPN_DOMAIN:110` |
| Direct VLESS/TCP | 443/TCP | 3x-ui VLESS link or Xray JSON profile |

OpenVPN and Cisco/AnyConnect use the same prompted VPN username and password. VLESS uses its own UUID; the username is only a label for the new VLESS client. On an existing 3x-ui server, `setup.sh` checks and preserves the direct VLESS/TCP inbound and panel. On a managed installation using the former port 10443, it adds port 443 with the existing client UUID and keeps 10443 available for existing clients. On a fresh server without 3x-ui, it installs 3x-ui and creates a TLS-protected VLESS/TCP inbound on 443. SSH accounts and other web services are left alone. OpenVPN uses a locally generated CA, server key, and `tls-crypt` key. No keys from the third-party installers are used.

## Prerequisites

1. Point the domain's A record to an IPv4 address on the server.
2. `setup.sh` uses an existing Let's Encrypt certificate or asks Certbot for one. If port 80 is free, HTTP validation is automatic; otherwise Certbot pauses for a manual DNS TXT challenge. A certificate issued through the manual TXT challenge **will not renew unattended**. Configure an automated DNS plugin before expiry or repeat manual issuance in time.
3. Ensure `/dev/net/tun` exists and that the OpenVPN and Cisco TCP/UDP ports are free and permitted by the provider firewall. A new 3x-ui installation also needs 443/TCP and panel port 2083/TCP free; restrict panel port 2083 to trusted IP addresses at the provider firewall where possible.
4. Review `setup.sh`, `install.sh`, `xui-install.sh`, `xui_inbound.py`, `xui_port.py`, `xui_client.py`, `auth.py`, `vpnctl.py`, and `rollback.sh` before running. On a shared or production server, take a provider snapshot first.
5. On Ubuntu 22.04, `ocserv` comes from the Ubuntu `universe` repository. Fresh setup enables `universe` if the package is unavailable, then refreshes the package lists. Direct use of `install.sh` requires `universe` to be enabled already.
6. The installer creates a dedicated `ocserv` system account when the package has not provided one. Rollback removes this account only if the installer created it.

## Interactive setup from a reviewed checkout

```bash
sudo bash ./setup.sh
```

The script asks for the domain, VPN username, and VPN password. It checks the current services and ports before changing them. On an existing managed VPN server, it updates the requested VPN account and preserves the 3x-ui direct TCP inbound; if it used port 10443, a new 443 inbound is added with the same client UUID. On a fresh server, it installs OpenVPN UDP/TCP, ocserv, and 3x-ui. It disables 3x-ui's unused subscription server on port 2096. It saves the single OpenVPN profile at `/etc/vpn-stack/clients/auto.ovpn`, a direct TCP client link at `/etc/vpn-stack-xui/client.txt`, a full Xray JSON client profile at `/etc/vpn-stack-xui/client.json`, and random panel login details at `/etc/x-ui/install-result.env`. These files are root-only. The JSON uses a local SOCKS listener on 127.0.0.1:10808, VLESS/TCP+TLS, the prompted domain for both address and SNI, and port 443. The client UUID is generated per server; it is never embedded in this public repository. The panel's HTTPS address is `https://VPN_DOMAIN:2083/` followed by the generated `XUI_WEB_BASE_PATH` from that credentials file. The panel password is separate from the prompted VPN password.

If an existing 3x-ui installation has no active VLESS/TCP direct inbound on port 443 or 10443, run `sudo bash ./setup.sh --vpn-only` to install OpenVPN and Cisco/AnyConnect while leaving 3x-ui as-is. This also works on a fresh server and skips 3x-ui installation. Use `--check --vpn-only` for the read-only check. Cisco/AnyConnect still uses TCP and UDP port 110.

Run a read-only check first, entering only the domain:

```bash
sudo bash ./setup.sh --check
```

For a first-time VPN-only installation with explicit certificate paths and custom ports, use `install.sh` directly. The 3x-ui installer is pinned to official v3.11.0 with a hardcoded SHA-256 checksum; it is downloaded to a file and verified before execution. Its release archive checksum is checked by the pinned installer. During initial installation, a temporary firewall rule blocks external access to panel port 2083 while the official installer starts the panel over HTTP. The rule is removed only after the existing domain certificate is installed and a local TLS check succeeds. Restrict the panel port to trusted IP addresses at the provider firewall for ongoing use.

The installer stops if it finds an existing VPN configuration, a port conflict, a route overlap, an unsupported OS, or a certificate mismatch. Custom port flags are `--udp-port`, `--tcp-port`, and `--ocserv-port`. Port 110 is traditionally used for POP3; the installer checks that it is free before assigning it to ocserv. The default VPN address pools are 10.77.0.0/24, 10.78.0.0/24, and 10.79.0.0/24; change these in the reviewed source before installation if they overlap your network.
Use `--egress-ip PUBLIC_IPV4` at installation to SNAT all three VPN networks to a public IPv4 address already assigned to the outbound interface. Without it, NAT uses the interface's default source IP.

## Operate

```bash
sudo vpnctl user add alice
sudo vpnctl user add alice --generate
sudo vpnctl user add alice --allow-short-password
sudo vpnctl user delete alice
sudo vpnctl profile auto
sudo vpnctl profile udp
sudo vpnctl profile tcp
sudo vpnctl status
sudo bash ./egress.sh YOUR_PUBLIC_IPV4 --check
sudo bash ./egress.sh YOUR_PUBLIC_IPV4
sudo bash ./egress.sh auto
```

Client profiles are stored with root-only permissions in `/etc/vpn-stack/clients/`. Distribute them securely. Give clients `auto.ovpn` as the single OpenVPN file: OpenVPN Connect tries UDP first and then TCP if UDP cannot connect. The separate UDP-only and TCP-only files are optional. The OpenVPN profiles prompt for the username and password. The ocserv address uses the same credentials. Deleting a user prevents new logins; disconnect any existing sessions separately.
With `--generate`, the password is placed in a root-only `.credentials` file beside the profiles and is never printed by the command. Retrieve it over SSH and delete that file afterward.
Passwords shorter than 12 characters require the explicit `--allow-short-password` flag. Such passwords are easy to guess; use a generated password for normal operation. This flag does not store a plaintext password.
`egress.sh` changes only the VPN NAT rule, checks that the chosen address belongs to the server, and can restore automatic source selection with `auto`. Existing VPN connections may keep their old external IP until they reconnect.
The client profiles use the domain name, so changing its A record to another IPv4 address assigned to the same server does not require new profiles. Allow DNS caches to expire and reconnect clients. `vpnctl status` checks that all resolved A records belong to this server and that the ocserv certificate covers the domain. Changing the domain's A record does not change the VPN's outgoing SNAT address.

Check logs with `journalctl -u openvpn-server@udp -u openvpn-server@tcp -u ocserv --since today`. Check local TLS with `openssl s_client -connect VPN_DOMAIN:110 -servername VPN_DOMAIN -verify_hostname VPN_DOMAIN` and test an authenticated connection from a separate device. Check certificate expiry with `sudo certbot certificates`. For a Certbot certificate, the installer adds a scoped deploy hook that reloads ocserv after renewal. A running service and open socket are only partial health checks; they do not prove the tunnel routes traffic end to end.

## Roll back

```bash
sudo bash /etc/vpn-stack/rollback.sh
```

Rollback stops and disables the managed VPN services and removes 3x-ui only if this project installed it, removes only this project's configurations, deletes its NAT table, and restores the previous IPv4 forwarding setting. It does not remove an existing 3x-ui installation. Installed Ubuntu packages and the public certificate are retained. OpenVPN CA and client profiles are deleted during rollback, so preserve any needed private backup securely. If installation fails after the managed files are created, rollback runs automatically.

## Security and limits

- A shared password across modes is convenient but creates one compromise point. Use a unique, long VPN password. The SSH password is never reused for VPN access.
- The OpenVPN CA private key stays on the server under `/etc/vpn-stack/pki/ca.key` with mode 600. Back it up securely or rotate the profiles if compromised.
- This project provides IPv4 tunnelling. IPv6 client traffic is not configured; configure client side IPv6 handling to prevent leaks if needed.
- The installer checks the host firewall policies it can see. A provider firewall or additional nftables chains can still block traffic. It does not flush or rewrite existing firewall rules.
- There is no claim of a successful end-to-end VPN test until a remote client connects and verifies external IP and DNS.

See [CERTIFICATE.md](CERTIFICATE.md) for manual renewal and a migration path to automatic Cloudflare DNS renewal.

## Review of the supplied third-party files

The `ocserv-almalinux8.sh` file requires `dnf` and changes firewalld, nginx, and sysctl settings. It downloads a server private key, certificate, nginx configuration, and ocserv configuration from a third-party site at install time. The `openvpn-almalinux8.zip` package explicitly requires AlmaLinux 8 and contains a reusable server private key. It sets TCP port 110 and includes changes to firewalld. Neither package is executed by this project, and their keys are not included in this repository.

