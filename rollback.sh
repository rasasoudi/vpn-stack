#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ -f /etc/vpn-stack/previous-forward ]] || { echo 'No managed installation found' >&2; exit 1; }
if [[ -f /etc/vpn-stack-xui/managed ]]; then
  systemctl disable --now x-ui 2>/dev/null || true
  nft delete table inet vpn_stack_xui_guard 2>/dev/null || true
  rm -f /etc/systemd/system/x-ui.service /usr/bin/x-ui
  rm -f /etc/letsencrypt/renewal-hooks/deploy/92-vpn-stack-xui
  rm -rf /usr/local/x-ui /etc/x-ui /etc/vpn-stack-xui
fi
systemctl disable --now openvpn-server@udp.service openvpn-server@tcp.service ocserv.service vpn-stack-firewall.service 2>/dev/null || true
nft delete table ip vpn_stack 2>/dev/null || true
previous=$(cat /etc/vpn-stack/previous-forward)
rm -f /etc/openvpn/server/udp.conf /etc/openvpn/server/tcp.conf /etc/ocserv/ocserv.conf
rm -f /etc/sysctl.d/90-vpn-stack.conf /etc/systemd/system/vpn-stack-firewall.service
rm -f /etc/letsencrypt/renewal-hooks/deploy/90-vpn-stack
rm -f /usr/local/libexec/vpn-stack-auth /usr/local/sbin/vpnctl
rm -rf /etc/vpn-stack
sysctl -q -w "net.ipv4.ip_forward=$previous"
systemctl daemon-reload
echo 'VPN Stack configuration removed; packages and external certificate were retained.'
