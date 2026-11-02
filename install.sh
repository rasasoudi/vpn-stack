#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOMAIN='' CERT='' KEY=''
EGRESS_IP=''
UDP_PORT=1194 TCP_PORT=1195 OCSERV_PORT=110
UDP_NET=10.77.0.0/24 TCP_NET=10.78.0.0/24 OCSERV_NET=10.79.0.0/24
DNS1=1.1.1.1 DNS2=9.9.9.9

usage() {
  echo 'Usage: sudo bash install.sh --domain vpn.example.com --cert /path/fullchain.pem --key /path/privkey.pem [--check]' >&2
}
CHECK=0
while (($#)); do
  case "$1" in
    --domain) DOMAIN=${2:?}; shift 2;;
    --cert) CERT=${2:?}; shift 2;;
    --key) KEY=${2:?}; shift 2;;
    --udp-port) UDP_PORT=${2:?}; shift 2;;
    --tcp-port) TCP_PORT=${2:?}; shift 2;;
    --ocserv-port) OCSERV_PORT=${2:?}; shift 2;;
    --egress-ip) EGRESS_IP=${2:?}; shift 2;;
    --check) CHECK=1; shift;;
    *) usage; exit 2;;
  esac
done
[[ $EUID == 0 && -n $DOMAIN && -n $CERT && -n $KEY ]] || { usage; exit 2; }
[[ $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $DOMAIN == *.* ]] || { echo 'Invalid domain' >&2; exit 2; }
for port in "$UDP_PORT" "$TCP_PORT"; do
  [[ $port =~ ^[0-9]+$ && $port -ge 1024 && $port -le 65535 ]] || { echo "Invalid port: $port" >&2; exit 2; }
done
[[ $OCSERV_PORT =~ ^[0-9]+$ && $OCSERV_PORT -ge 1 && $OCSERV_PORT -le 65535 ]] || { echo "Invalid ocserv port: $OCSERV_PORT" >&2; exit 2; }
[[ $UDP_PORT != "$OCSERV_PORT" && $TCP_PORT != "$OCSERV_PORT" ]] || { echo 'Ports must be distinct' >&2; exit 2; }
source /etc/os-release
[[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 || $VERSION_ID == 26.04 ) ]] || { echo 'Supported: Ubuntu 22.04, 24.04 or 26.04' >&2; exit 1; }
[[ -c /dev/net/tun ]] || { echo '/dev/net/tun is unavailable' >&2; exit 1; }
for cmd in openssl python3 ip ss nft iptables apt-get apt-cache systemctl getent; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }; done
ocserv_candidate=$(apt-cache policy ocserv | awk '$1 == "Candidate:" {print $2}')
if [[ -z $ocserv_candidate || $ocserv_candidate == '(none)' ]]; then
  echo 'ocserv is unavailable; enable the Ubuntu universe repository and run apt-get update' >&2; exit 1
fi
[[ -r $CERT && -r $KEY ]] || { echo 'Certificate or private key is unreadable' >&2; exit 1; }
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" | grep -q 'does match' || { echo 'Certificate does not cover domain' >&2; exit 1; }
[[ $(openssl x509 -in "$CERT" -noout -pubkey | openssl sha256) == "$(openssl pkey -in "$KEY" -pubout 2>/dev/null | openssl sha256)" ]] || { echo 'Certificate and key do not match' >&2; exit 1; }
openssl x509 -in "$CERT" -checkend 604800 -noout >/dev/null || { echo 'Certificate expires within seven days' >&2; exit 1; }

DOMAIN_IPS=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
LOCAL_IPS=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
[[ -n $DOMAIN_IPS ]] || { echo 'Domain has no IPv4 address' >&2; exit 1; }
while read -r ip; do grep -Fxq "$ip" <<<"$LOCAL_IPS" && FOUND_IP=1; done <<<"$DOMAIN_IPS"
[[ ${FOUND_IP:-0} == 1 ]] || { echo 'Domain does not resolve to an IPv4 address on this host' >&2; exit 1; }
IFACE=$(ip -4 route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
[[ -n $IFACE ]] || { echo 'Could not find outbound interface' >&2; exit 1; }
NAT_ACTION=masquerade
if [[ -n $EGRESS_IP ]]; then
  python3 - "$EGRESS_IP" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if ip.version != 4 or not ip.is_global:
    raise SystemExit('Egress IP must be a public IPv4 address')
PY
  ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$EGRESS_IP" || { echo 'Egress IP is not assigned to outbound interface' >&2; exit 1; }
  ip -4 route get 1.1.1.1 from "$EGRESS_IP" | grep -Fq "dev $IFACE" || { echo 'Egress IP has no outbound route on interface' >&2; exit 1; }
  NAT_ACTION="snat to $EGRESS_IP"
fi
[[ ! -e /etc/vpn-stack && ! -e /etc/openvpn/server/udp.conf && ! -e /etc/openvpn/server/tcp.conf && ! -e /etc/ocserv/ocserv.conf ]] || { echo 'Existing VPN configuration detected; refusing to overwrite' >&2; exit 1; }
for service in ocserv.service openvpn-server@udp.service openvpn-server@tcp.service; do
  systemctl is-active --quiet "$service" && { echo "Existing service is active: $service" >&2; exit 1; }
done
[[ ! -e /etc/letsencrypt/renewal-hooks/deploy/90-vpn-stack ]] || { echo 'Existing vpn-stack renewal hook detected' >&2; exit 1; }
nft list table ip vpn_stack >/dev/null 2>&1 && { echo 'vpn_stack firewall table already exists' >&2; exit 1; }
for spec in "udp:$UDP_PORT" "tcp:$TCP_PORT" "tcp:$OCSERV_PORT" "udp:$OCSERV_PORT"; do
  proto=${spec%%:*}; port=${spec#*:}
  ss -H -ln"${proto:0:1}" | awk '{print $5}' | grep -Eq ":${port}$" && { echo "Port in use: $spec" >&2; exit 1; }
done
python3 - "$UDP_NET" "$TCP_NET" "$OCSERV_NET" <<'PY'
import ipaddress, subprocess, sys
nets = [ipaddress.ip_network(x) for x in sys.argv[1:]]
routes = subprocess.check_output(['ip', '-4', '-o', 'route', 'show', 'table', 'all'], text=True)
for line in routes.splitlines():
    try: route = ipaddress.ip_network(line.split()[0], strict=False)
    except ValueError: continue
    if route.prefixlen and any(route.overlaps(net) for net in nets):
        raise SystemExit(f'VPN subnet overlaps route: {route}')
PY
[[ $(iptables -S FORWARD | head -1) == '-P FORWARD ACCEPT' ]] || { echo 'Existing FORWARD policy needs manual review' >&2; exit 1; }
[[ $(iptables -S INPUT | head -1) == '-P INPUT ACCEPT' ]] || { echo 'Existing INPUT policy needs manual review' >&2; exit 1; }
echo "Preflight OK: $ID $VERSION_ID, domain $DOMAIN, interface $IFACE, ports UDP $UDP_PORT, TCP $TCP_PORT, ocserv $OCSERV_PORT"
((CHECK == 0)) || exit 0

install -d -m 700 /etc/vpn-stack /etc/vpn-stack/pki /etc/vpn-stack/clients
install -d -m 755 /usr/local/libexec
printf '%s\n' "$(sysctl -n net.ipv4.ip_forward)" > /etc/vpn-stack/previous-forward
install -m 700 "$ROOT/rollback.sh" /etc/vpn-stack/rollback.sh
trap 'echo "Install failed; rolling back managed files" >&2; /etc/vpn-stack/rollback.sh --failed' ERR

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openvpn ocserv nftables python3 openssl
systemctl stop ocserv.service 2>/dev/null || true
if ! getent group ocserv >/dev/null; then
  groupadd --system ocserv
  touch /etc/vpn-stack/created-ocserv-group
fi
if ! getent passwd ocserv >/dev/null; then
  useradd --system --gid ocserv --home-dir /nonexistent --shell /usr/sbin/nologin ocserv
  touch /etc/vpn-stack/created-ocserv-user
fi
install -m 755 "$ROOT/auth.py" /usr/local/libexec/vpn-stack-auth
install -m 700 "$ROOT/vpnctl.py" /usr/local/sbin/vpnctl
install -d -m 750 -o root -g nogroup /etc/vpn-stack
printf '{}\n' > /etc/vpn-stack/users.json
chown root:nogroup /etc/vpn-stack/users.json
chmod 640 /etc/vpn-stack/users.json
touch /etc/vpn-stack/ocpasswd
chmod 600 /etc/vpn-stack/ocpasswd

openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -keyout /etc/vpn-stack/pki/ca.key -out /etc/vpn-stack/pki/ca.crt -subj '/CN=VPN Stack CA' >/dev/null 2>&1
openssl req -newkey rsa:3072 -nodes -sha256 -keyout /etc/vpn-stack/pki/server.key -out /etc/vpn-stack/pki/server.csr -subj "/CN=$DOMAIN" >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$DOMAIN" > /etc/vpn-stack/pki/server.ext
openssl x509 -req -in /etc/vpn-stack/pki/server.csr -CA /etc/vpn-stack/pki/ca.crt -CAkey /etc/vpn-stack/pki/ca.key -CAcreateserial -days 825 -sha256 -extfile /etc/vpn-stack/pki/server.ext -out /etc/vpn-stack/pki/server.crt >/dev/null 2>&1
openvpn --genkey tls-crypt /etc/vpn-stack/pki/tls-crypt.key >/dev/null
chmod 600 /etc/vpn-stack/pki/*

install -d -m 700 /etc/openvpn/server /etc/ocserv
for item in "udp $UDP_PORT $UDP_NET" "tcp $TCP_PORT $TCP_NET"; do
  read -r proto port cidr <<<"$item"
  net=${cidr%/*}
  cat > "/etc/openvpn/server/$proto.conf" <<EOF
port $port
proto $([[ $proto == udp ]] && echo udp4 || echo tcp4-server)
dev tun-$proto
topology subnet
server $net 255.255.255.0
ca /etc/vpn-stack/pki/ca.crt
cert /etc/vpn-stack/pki/server.crt
key /etc/vpn-stack/pki/server.key
dh none
tls-crypt /etc/vpn-stack/pki/tls-crypt.key
verify-client-cert none
username-as-common-name
script-security 2
auth-user-pass-verify /usr/local/libexec/vpn-stack-auth via-file
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
verb 3
EOF
done
cat > /etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/vpn-stack/ocpasswd]"
tcp-port = $OCSERV_PORT
udp-port = $OCSERV_PORT
server-cert = $CERT
server-key = $KEY
socket-file = /run/ocserv-socket
run-as-user = ocserv
run-as-group = ocserv
device = vpns
ipv4-network = ${OCSERV_NET%/*}
ipv4-netmask = 255.255.255.0
dns = $DNS1
dns = $DNS2
route = default
max-clients = 128
max-same-clients = 2
EOF
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-vpn-stack.conf
sysctl -q -p /etc/sysctl.d/90-vpn-stack.conf
cat > /etc/vpn-stack/firewall.nft <<EOF
table ip vpn_stack {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { $UDP_NET, $TCP_NET, $OCSERV_NET } oifname "$IFACE" $NAT_ACTION
  }
}
EOF
cat > /etc/systemd/system/vpn-stack-firewall.service <<'EOF'
[Unit]
Description=VPN Stack isolated NAT rules
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/vpn-stack/firewall.nft
ExecStop=/usr/sbin/nft delete table ip vpn_stack
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/vpn-stack/settings.json <<EOF
{"domain":"$DOMAIN","cert":"$CERT","udp_port":$UDP_PORT,"tcp_port":$TCP_PORT,"ocserv_port":$OCSERV_PORT}
EOF
if [[ $CERT == /etc/letsencrypt/live/*/fullchain.pem ]]; then
  CERT_DIR=$(dirname "$CERT")
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/90-vpn-stack <<EOF
#!/usr/bin/env bash
[[ \${RENEWED_LINEAGE:-} == '$CERT_DIR' ]] && systemctl try-reload-or-restart ocserv.service || true
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/90-vpn-stack
fi
python3 -m py_compile /usr/local/libexec/vpn-stack-auth /usr/local/sbin/vpnctl
ocserv --test-config -c /etc/ocserv/ocserv.conf
systemctl daemon-reload
systemctl enable --now vpn-stack-firewall.service
systemctl enable --now openvpn-server@udp.service openvpn-server@tcp.service ocserv.service
/usr/local/sbin/vpnctl profile udp
/usr/local/sbin/vpnctl profile tcp
/usr/local/sbin/vpnctl profile auto
/usr/local/sbin/vpnctl status
trap - ERR
echo 'Installation complete. Create a VPN user with: sudo vpnctl user add NAME'
