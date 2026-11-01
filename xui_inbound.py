#!/usr/bin/env python3
"""Create one TLS protected VLESS/TCP inbound through a new local 3x-ui API."""
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
import uuid


def main() -> int:
    domain, username, cert, key, panel_port, direct_port = sys.argv[1:]
    credentials = {}
    for line in pathlib.Path("/etc/x-ui/install-result.env").read_text().splitlines():
        name, sep, value = line.partition("=")
        if sep and name in {"XUI_WEB_BASE_PATH", "XUI_API_TOKEN"}:
            # The official installer writes shell-escaped alphanumeric values.
            if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
                raise ValueError(f"Unexpected {name} in installer output")
            credentials[name] = value
    path = credentials["XUI_WEB_BASE_PATH"].strip("/")
    token = credentials["XUI_API_TOKEN"]
    base = f"http://127.0.0.1:{int(panel_port)}/{path}/panel/api/inbounds"

    def api(method, suffix, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            base + suffix, data=data, method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)
        if not result.get("success"):
            raise RuntimeError(f"3x-ui API rejected {suffix}: {result.get('msg', 'unknown error')}")
        return result

    for attempt in range(15):
        try:
            existing = api("GET", "/list")["obj"]
            break
        except (OSError, ValueError, RuntimeError):
            if attempt == 14:
                raise
            time.sleep(1)
    if any(int(row.get("port", 0)) == int(direct_port) for row in existing):
        raise RuntimeError("Direct TCP port already has a 3x-ui inbound")
    client_id = str(uuid.uuid4())
    payload = {
        "enable": True,
        "remark": "vpn-stack-direct-tcp",
        "listen": "",
        "port": int(direct_port),
        "protocol": "vless",
        "expiryTime": 0,
        "total": 0,
        "settings": {"clients": [{"id": client_id, "email": username, "enable": True}], "decryption": "none", "fallbacks": []},
        "streamSettings": {
            "network": "tcp", "security": "tls",
            "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}},
            "tlsSettings": {"serverName": domain, "certificates": [{"certificateFile": cert, "keyFile": key}]},
        },
        "sniffing": {"enabled": False, "destOverride": []},
    }
    api("POST", "/add", payload)
    link = (f"vless://{client_id}@{domain}:{direct_port}?"
            + urllib.parse.urlencode({"type": "tcp", "security": "tls", "sni": domain})
            + "#" + urllib.parse.quote(username))
    output = pathlib.Path("/etc/vpn-stack-xui/client.txt")
    output.write_text(link + "\n")
    output.chmod(0o600)
    print("VLESS/TCP+TLS inbound created in 3x-ui; client link saved root-only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
