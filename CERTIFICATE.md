# TLS certificate renewal

`setup.sh` uses an existing public certificate or requests one through Certbot. If port 80 is free, it uses HTTP validation; if busy, Certbot prompts for a manual DNS TXT challenge. The certificate path is stored in `/etc/vpn-stack/settings.json`, and `vpnctl status` warns when fewer than seven days remain. On a fresh server with managed 3x-ui, a root-owned renewal hook restarts 3x-ui after a successful renewal so its panel and direct TCP inbound use the new certificate. No private key is included in the repository.

## Manual DNS challenge

If the certificate was issued with Certbot's `--manual` DNS challenge, it **does not renew automatically**. Well before expiry, run:

```bash
sudo certbot certonly --manual --preferred-challenges dns --cert-name vpn.example.com -d vpn.example.com
```

Certbot will show a new TXT value for `_acme-challenge.vpn.example.com`. Add that value in the domain's DNS dashboard, verify it is publicly visible, and then press Enter in Certbot. The old challenge TXT value may be deleted after issuance. Repeat this process before each expiry, or switch to an automated DNS plugin. The project's Certbot deploy hooks reload ocserv and, when installed by this project, restart 3x-ui only when this certificate renews.

If Certbot reports `NXDOMAIN`, the TXT name is absent from public DNS. For a delegated `your-name.dpdns.org` domain, create the TXT record in the external authoritative DNS service, usually with the relative name `_acme-challenge` in the `your-name.dpdns.org` zone. The DigitalPlat registration dashboard is not a DNS record editor. Install `dnsutils` if `dig` is missing. Before pressing Enter, check the exact value Certbot displayed:

```bash
dig +short NS your-name.dpdns.org
dig +short TXT _acme-challenge.your-name.dpdns.org @1.1.1.1
dig +short TXT _acme-challenge.your-name.dpdns.org @8.8.8.8
```

If the value is missing, check the record name in your DNS provider and wait for the new record to propagate. After a failed attempt, start Certbot again and use the new TXT value it displays.

## Automatic Cloudflare DNS renewal

For a Cloudflare hosted domain, create an API token limited to **Zone → DNS → Edit** for that one DNS zone. Keep the token out of the repository and chat logs. On the server:

```bash
sudo apt-get install -y --no-install-recommends python3-certbot-dns-cloudflare
sudo install -m 600 /dev/null /etc/letsencrypt/cloudflare.ini
sudoedit /etc/letsencrypt/cloudflare.ini
```

Put this single line in the root-only file, replacing the example with the restricted token:

```ini
dns_cloudflare_api_token = YOUR_RESTRICTED_TOKEN
```

Then switch the existing certificate lineage to the DNS plugin and test renewal:

```bash
sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini --dns-cloudflare-propagation-seconds 60 --cert-name vpn.example.com -d vpn.example.com
sudo certbot renew --dry-run --cert-name vpn.example.com
```

If Certbot asks to replace the existing certificate, inspect the domain and certificate name before accepting. Check the resulting lineage under `/etc/letsencrypt/renewal/` to confirm it uses the Cloudflare authenticator. Keep the token file at mode 600. After a successful renewal, `sudo vpnctl status` should show the certificate as healthy.
