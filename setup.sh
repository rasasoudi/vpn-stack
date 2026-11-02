#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CHECK=0 VPN_ONLY=0
for option in "$@"; do
  case "$option" in
    --check) CHECK=1 ;;
    --vpn-only) VPN_ONLY=1 ;;
    *) echo 'Usage: sudo bash setup.sh [--check] [--vpn-only]' >&2; exit 2 ;;
  esac
done
FRESH_INSTALLED=0
cleanup() {
  result=$?
  unset PASSWORD CONFIRM
  if (( result != 0 && FRESH_INSTALLED == 1 )); then
    bash "$ROOT/rollback.sh" || true
  fi
}
trap cleanup EXIT
[[ $EUID == 0 && -t 0 ]] || {
  echo 'Run in an interactive root terminal: sudo bash setup.sh [--check] [--vpn-only]' >&2; exit 2;
}
read -r -p 'VPN domain (example: vpn.example.com): ' DOMAIN
[[ $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $DOMAIN == *.* ]] || {
  echo 'Invalid domain' >&2; exit 2;
}
source /etc/os-release
[[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 || $VERSION_ID == 26.04 ) ]] || {
  echo 'Supported: Ubuntu 22.04, 24.04 or 26.04' >&2; exit 1;
}
[[ -c /dev/net/tun ]] || { echo '/dev/net/tun is unavailable' >&2; exit 1; }

if [[ -d /etc/vpn-stack ]]; then
  [[ -f /etc/vpn-stack/previous-forward ]] || { echo 'Existing VPN directory is not managed by this project' >&2; exit 1; }
  existing_domain=$(python3 -c 'import json; print(json.load(open("/etc/vpn-stack/settings.json"))["domain"])')
  [[ $existing_domain == "$DOMAIN" ]] || { echo "Existing VPN uses $existing_domain; domain migration needs a separate review" >&2; exit 1; }
  /usr/local/sbin/vpnctl status
  FRESH=0
else
  FRESH=1
fi

if [[ $VPN_ONLY == 1 ]]; then
  DIRECT=vpn-only
elif [[ -e /usr/local/x-ui/x-ui || -e /etc/x-ui/x-ui.db ]]; then
  python3 "$ROOT/xui_direct.py"
  [[ ! -f /etc/vpn-stack-xui/managed ]] || python3 "$ROOT/xui_port.py" --check "$DOMAIN"
  DIRECT=existing-3x-ui
else
  DIRECT=new-3x-ui
  ss -H -lnt | awk '{print $4}' | grep -Eq ':443$|:2083$' && { echo 'TCP port 443 or 2083 is occupied' >&2; exit 1; }
fi

if command -v getent >/dev/null && command -v ip >/dev/null; then
  domain_ips=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
  local_ips=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
  [[ -n $domain_ips ]] || { echo 'Domain has no IPv4 A record' >&2; exit 1; }
  while read -r addr; do
    grep -Fxq "$addr" <<<"$local_ips" || { echo "Domain address $addr is not on this server" >&2; exit 1; }
  done <<<"$domain_ips"
fi

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [[ $CHECK == 1 ]]; then
  if [[ -r $CERT && -r $KEY ]]; then
    openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" | grep -q 'does match' || exit 1
    openssl x509 -in "$CERT" -checkend 604800 -noout >/dev/null || exit 1
    echo 'Certificate: valid for domain, more than seven days remain'
  else
    echo 'Certificate: missing; setup will request one with Certbot'
  fi
  echo "VPN stack: $([[ $FRESH == 1 ]] && echo new || echo existing); direct TCP: $DIRECT"
  exit 0
fi

read -r -p 'VPN username: ' USERNAME
[[ $USERNAME =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || { echo 'Invalid username' >&2; exit 2; }
read -r -s -p 'VPN password: ' PASSWORD; echo
read -r -s -p 'Confirm VPN password: ' CONFIRM; echo
[[ ${#PASSWORD} -ge 4 && ${#PASSWORD} -le 1024 && $PASSWORD == "$CONFIRM" ]] || {
  echo 'Passwords must match and be 4-1024 characters' >&2; exit 2;
}
if (( ${#PASSWORD} < 12 )); then echo 'Warning: this password is easy to guess' >&2; fi
unset CONFIRM

if [[ $FRESH == 1 ]]; then
  apt-get update
  ocserv_candidate=$(apt-cache policy ocserv | awk '$1 == "Candidate:" {print $2}')
  if [[ $VERSION_ID == 22.04 && ( -z $ocserv_candidate || $ocserv_candidate == '(none)' ) ]]; then
    echo 'Enabling Ubuntu universe for the ocserv package...'
    DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update
    ocserv_candidate=$(apt-cache policy ocserv | awk '$1 == "Candidate:" {print $2}')
  fi
  [[ -n $ocserv_candidate && $ocserv_candidate != '(none)' ]] || {
    echo 'ocserv is unavailable from configured Ubuntu repositories' >&2; exit 1;
  }
fi

if [[ ! -r $CERT || ! -r $KEY ]]; then
  echo 'Installing Certbot to request a certificate for the domain...'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl python3 iproute2 nftables iptables certbot
  if ss -H -lnt | awk '{print $4}' | grep -Eq ':80$'; then
    echo 'Port 80 is busy. Certbot will ask for a DNS TXT record.'
    certbot certonly --manual --preferred-challenges dns --agree-tos --register-unsafely-without-email -d "$DOMAIN"
  else
    certbot certonly --standalone --preferred-challenges http --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN"
  fi
fi
[[ -r $CERT && -r $KEY ]] || { echo 'Certificate issuance did not complete' >&2; exit 1; }
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" | grep -q 'does match' || { echo 'Certificate does not cover domain' >&2; exit 1; }

if [[ $FRESH == 1 ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl python3 iproute2 nftables iptables
  bash "$ROOT/install.sh" --domain "$DOMAIN" --cert "$CERT" --key "$KEY" --check
  if [[ $DIRECT == new-3x-ui ]]; then
    bash "$ROOT/xui-install.sh" --check "$DOMAIN" "$USERNAME" "$CERT" "$KEY"
  fi
  bash "$ROOT/install.sh" --domain "$DOMAIN" --cert "$CERT" --key "$KEY"
  FRESH_INSTALLED=1
fi

install -m 700 "$ROOT/vpnctl.py" /usr/local/sbin/vpnctl
password_args=()
if (( ${#PASSWORD} < 12 )); then password_args+=(--allow-short-password); fi
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | /usr/local/sbin/vpnctl user add "$USERNAME" --password-stdin "${password_args[@]}"
unset PASSWORD

if [[ $DIRECT == new-3x-ui ]]; then
  bash "$ROOT/xui-install.sh" --install "$DOMAIN" "$USERNAME" "$CERT" "$KEY"
elif [[ $DIRECT == existing-3x-ui && -f /etc/vpn-stack-xui/managed ]]; then
  python3 "$ROOT/xui_port.py" --migrate "$DOMAIN"
fi
/usr/local/sbin/vpnctl status
echo "OpenVPN single client file: /etc/vpn-stack/clients/auto.ovpn"
echo "Cisco/AnyConnect server: https://$DOMAIN:110"
case "$DIRECT" in
  existing-3x-ui) echo 'Existing 3x-ui VLESS/TCP direct inbound checked; managed legacy installations also use port 443' ;;
  new-3x-ui) echo 'VLESS/TCP+TLS client link and Xray JSON: /etc/vpn-stack-xui/client.txt, client.json (root only)' ;;
  vpn-only) echo '3x-ui was left as-is; this installation provides OpenVPN and Cisco/AnyConnect only' ;;
esac

