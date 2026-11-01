#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION=v3.11.0
INSTALLER_SHA256=9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d
MARKER=/etc/vpn-stack-xui/managed
PANEL_PORT=2083
DIRECT_PORT=443

case "${1:-}" in
  --check)
    [[ $# == 5 ]] || exit 2
    domain=$2; username=$3; cert=$4; key=$5
    [[ $EUID == 0 && $(uname -m) == x86_64 ]] || { echo '3x-ui setup requires root and x86_64' >&2; exit 1; }
    [[ -r $cert && -r $key ]] || { echo 'Certificate or key unreadable' >&2; exit 1; }
    openssl x509 -in "$cert" -noout -checkhost "$domain" | grep -q 'does match' || {
      echo 'Certificate does not match domain' >&2; exit 1;
    }
    [[ $username =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || exit 2
    [[ ! -e /etc/x-ui/x-ui.db && ! -e /usr/local/x-ui/x-ui && ! -e $MARKER ]] || {
      echo '3x-ui already exists; refusing to replace it' >&2; exit 1;
    }
    nft list table inet vpn_stack_xui_guard >/dev/null 2>&1 && {
      echo 'Temporary panel firewall guard already exists' >&2; exit 1;
    }
    for port in "$PANEL_PORT" "$DIRECT_PORT"; do
      if ss -H -lnt | awk '{print $4}' | grep -Eq ":${port}$"; then
        echo "TCP port $port is occupied" >&2; exit 1
      fi
    done
    ;;
  --install)
    [[ $# == 5 ]] || exit 2
    domain=$2; username=$3; cert=$4; key=$5
    bash "$0" --check "$domain" "$username" "$cert" "$key"
    install -d -m 700 /etc/vpn-stack-xui
    : > "$MARKER"
    chmod 600 "$MARKER"
    nft add table inet vpn_stack_xui_guard
    nft 'add chain inet vpn_stack_xui_guard input { type filter hook input priority -300; policy accept; }'
    nft add rule inet vpn_stack_xui_guard input tcp dport "$PANEL_PORT" iifname != lo drop
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/MHSanaei/3x-ui/$VERSION/install.sh" -o "$temp/install.sh"
    printf '%s  %s\n' "$INSTALLER_SHA256" "$temp/install.sh" | sha256sum -c --status || {
      echo '3x-ui installer checksum mismatch' >&2; exit 1;
    }
    # The pinned upstream installer validates the release archive checksum.
    # Its plain-HTTP stage uses a random path and credentials, then is promptly
    # replaced by the already validated domain certificate below.
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_PANEL_PORT=$PANEL_PORT \
      XUI_ENABLE_FAIL2BAN=false bash "$temp/install.sh" "$VERSION" > /etc/vpn-stack-xui/install.log 2>&1 || {
        echo '3x-ui installation failed; see /etc/vpn-stack-xui/install.log' >&2; exit 1;
      }
    [[ -x /usr/local/x-ui/x-ui && -r /etc/x-ui/install-result.env ]] || {
      echo '3x-ui installation incomplete' >&2; exit 1;
    }
    chown -R root:root /usr/local/x-ui
    # 3x-ui enables a separate subscription server on TCP 2096 by default.
    # This stack supplies a direct client link, so no subscription listener is needed.
    python3 - <<'PY'
import sqlite3
db = sqlite3.connect('/etc/x-ui/x-ui.db')
updated = db.execute("update settings set value = 'false' where key = 'subEnable'")
if updated.rowcount == 0:
    db.execute("insert into settings (key, value) values ('subEnable', 'false')")
db.commit()
PY
    python3 "$(dirname "$0")/xui_inbound.py" "$domain" "$username" "$cert" "$key" "$PANEL_PORT" "$DIRECT_PORT"
    /usr/local/x-ui/x-ui cert -webCert "$cert" -webCertKey "$key" > /etc/vpn-stack-xui/cert.log 2>&1
    systemctl restart x-ui
    ready=0
    for attempt in {1..30}; do
      if systemctl is-active --quiet x-ui \
        && { echo | openssl s_client -connect "127.0.0.1:$PANEL_PORT" -servername "$domain" 2>/dev/null \
          | openssl x509 -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; } \
        && ss -H -lnt | awk '{print $4}' | grep -Eq ":${DIRECT_PORT}$"; then
        ready=1
        break
      fi
      sleep 1
    done
    [[ $ready == 1 ]] || { echo '3x-ui panel TLS or direct TCP readiness check failed' >&2; exit 1; }
    if ss -H -lnt | awk '{print $4}' | grep -Eq ':2096$'; then
      echo 'Unused 3x-ui subscription port is still listening' >&2; exit 1
    fi
    python3 - "$domain" "$PANEL_PORT" <<'PY'
import pathlib, re, sys
path = pathlib.Path('/etc/x-ui/install-result.env')
lines = path.read_text().splitlines()
webpath = next(line.split('=', 1)[1] for line in lines if line.startswith('XUI_WEB_BASE_PATH='))
if not re.fullmatch(r'[A-Za-z0-9_-]+', webpath):
    raise SystemExit('Unexpected panel path in installer output')
url = f'XUI_ACCESS_URL=https://{sys.argv[1]}:{sys.argv[2]}/{webpath}'
path.write_text('\n'.join(url if line.startswith('XUI_ACCESS_URL=') else line for line in lines) + '\n')
path.chmod(0o600)
PY
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/92-vpn-stack-xui <<EOF
#!/bin/sh
[ "\${RENEWED_LINEAGE:-}" = "$(dirname "$cert")" ] && systemctl restart x-ui
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/92-vpn-stack-xui
    nft delete table inet vpn_stack_xui_guard
    echo '3x-ui direct TCP installed. Root-only panel details: /etc/x-ui/install-result.env'
    echo 'Root-only direct TCP client link and Xray JSON: /etc/vpn-stack-xui/client.txt, client.json'
    ;;
  --remove)
    [[ $EUID == 0 ]] || exit 1
    [[ -f $MARKER ]] || { echo 'No managed 3x-ui installation found' >&2; exit 1; }
    systemctl disable --now x-ui 2>/dev/null || true
    nft delete table inet vpn_stack_xui_guard 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service /usr/bin/x-ui /etc/letsencrypt/renewal-hooks/deploy/92-vpn-stack-xui
    rm -rf /usr/local/x-ui /etc/x-ui /etc/vpn-stack-xui
    systemctl daemon-reload
    echo 'Managed 3x-ui installation removed'
    ;;
  *) echo 'Usage: xui-install.sh --check|--install DOMAIN USER CERT KEY | --remove' >&2; exit 2 ;;
esac

