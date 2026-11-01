#!/usr/bin/env python3
"""Write a local Xray VLESS/TCP+TLS client profile for this installation."""
import json
import pathlib
import uuid


def write_client(domain: str, port: int, client_id: str) -> None:
    uuid.UUID(client_id)
    profile = {
        "remarks": f"{domain}-vless-tcp-tls-{port}",
        "log": {"loglevel": "warning"},
        "dns": {"servers": ["1.1.1.1"], "tag": "dns-module"},
        "inbounds": [{
            "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": False},
            "tag": "socks",
        }],
        "outbounds": [{
            "tag": "proxy", "protocol": "vless",
            "settings": {"vnext": [{
                "address": domain, "port": port,
                "users": [{"id": client_id, "encryption": "none"}],
            }]},
            "streamSettings": {
                "network": "tcp", "security": "tls",
                "tlsSettings": {"serverName": domain, "alpn": ["h2", "http/1.1"], "fingerprint": "chrome"},
                "tcpSettings": {"header": {"type": "none"}},
                "sockopt": {"domainStrategy": "UseIPv4"},
            },
        }, {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
        "routing": {"domainStrategy": "AsIs", "rules": [
            {"type": "field", "inboundTag": ["dns-module"], "outboundTag": "direct"},
            {"type": "field", "port": "0-65535", "outboundTag": "proxy"},
        ]},
    }
    path = pathlib.Path("/etc/vpn-stack-xui/client.json")
    path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)

