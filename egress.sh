#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: sudo bash egress.sh PUBLIC_IPV4|auto [--check]' >&2; exit 2; }
TARGET=$1
CHECK=${2:-}
[[ -z $CHECK || $CHECK == --check ]] || { echo 'Unknown option' >&2; exit 2; }
FILE=/etc/vpn-stack/firewall.nft
[[ -f $FILE ]] || { echo 'Managed VPN firewall not found' >&2; exit 1; }
systemctl is-active --quiet vpn-stack-firewall.service || { echo 'VPN firewall service is inactive' >&2; exit 1; }
IFACE=$(sed -nE 's/.*oifname "([^"]+)".*/\1/p' "$FILE" | head -1)
[[ -n $IFACE ]] || { echo 'Cannot detect outbound interface from VPN rules' >&2; exit 1; }
ACTION=masquerade
if [[ $TARGET != auto ]]; then
  python3 - "$TARGET" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if ip.version != 4 or not ip.is_global:
    raise SystemExit('Target must be a public IPv4 address')
PY
  ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$TARGET" || { echo 'Target IP is not assigned to outbound interface' >&2; exit 1; }
  ip -4 route get 1.1.1.1 from "$TARGET" | grep -Fq "dev $IFACE" || { echo 'Target IP has no route on outbound interface' >&2; exit 1; }
  ACTION="snat to $TARGET"
fi
NEW=$(mktemp /etc/vpn-stack/.firewall-new.XXXXXX)
OLD=$(mktemp /etc/vpn-stack/.firewall-old.XXXXXX)
trap 'rm -f "$NEW" "$OLD"' EXIT
cp -a "$FILE" "$OLD"
python3 - "$FILE" "$NEW" "$ACTION" <<'PY'
from pathlib import Path
import re, sys
old = Path(sys.argv[1]).read_text()
pattern = r'(?m)^(\s*ip saddr \{ [^}]+ \} oifname "[^"]+") (?:masquerade|snat to [0-9.]+)$'
new, count = re.subn(pattern, lambda m: m.group(1) + ' ' + sys.argv[3], old)
if count != 1:
    raise SystemExit('Expected exactly one managed NAT rule')
Path(sys.argv[2]).write_text(new)
PY
nft -c -f "$NEW"
if [[ $CHECK == --check ]]; then
  echo "Egress change is valid: $TARGET via $IFACE"
  exit 0
fi
install -m 600 "$NEW" "$FILE"
if ! systemctl restart vpn-stack-firewall.service; then
  install -m 600 "$OLD" "$FILE"
  systemctl restart vpn-stack-firewall.service || true
  echo 'Egress change failed; previous NAT rule restored' >&2
  exit 1
fi
echo "VPN IPv4 egress set to $TARGET"
nft list table ip vpn_stack
