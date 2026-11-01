#!/usr/bin/env python3
"""Add port 443 to a managed legacy 3x-ui installation, preserving port 10443."""
import argparse
import json
import pathlib
import re
import socket
import sqlite3
import ssl
import sys
import time
import urllib.parse
import urllib.request
import uuid

from xui_client import write_client

DB = pathlib.Path("/etc/x-ui/x-ui.db")
ENV = pathlib.Path("/etc/x-ui/install-result.env")
DIRECT_DIR = pathlib.Path("/etc/vpn-stack-xui")


def inbounds():
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True) as db:
        return db.execute(
            "select id, enable, port, protocol, remark, settings, stream_settings "
            "from inbounds where port in (443, 10443)"
        ).fetchall()


def validate(row, domain, *, legacy=False):
    inbound_id, enabled, port, protocol, remark, settings_raw, stream_raw = row
    allowed = {"vpn-stack-direct-tcp"} if legacy else {"vpn-stack-direct-tcp", "vpn-stack-direct-tcp-443"}
    settings, stream = json.loads(settings_raw), json.loads(stream_raw)
    if (not enabled or protocol != "vless" or remark not in allowed
            or settings.get("decryption") != "none" or not settings.get("clients")
            or stream.get("network") != "tcp" or stream.get("security") != "tls"
            or stream.get("tcpSettings", {}).get("header", {}).get("type", "none") != "none"
            or stream.get("tlsSettings", {}).get("serverName") != domain):
        raise RuntimeError(f"Port {port} is not the expected managed VLESS/TCP+TLS inbound")
    for client in settings["clients"]:
        uuid.UUID(client["id"])
    return inbound_id, settings, stream


def credentials(domain):
    env = dict(line.split("=", 1) for line in ENV.read_text().splitlines() if "=" in line)
    path, token = env["XUI_WEB_BASE_PATH"], env["XUI_API_TOKEN"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", path) or not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise RuntimeError("Unexpected 3x-ui panel credentials format")
    url = f"https://{domain}:2083/{path}/panel/api/inbounds"

    def api(method, suffix, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            url + suffix, data=data, method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.load(response)
        if not result.get("success"):
            raise RuntimeError(f"3x-ui API rejected {method} {suffix}: {result.get('msg', 'unknown error')}")
        return result

    return api


def tls_ready(domain):
    try:
        with socket.create_connection(("127.0.0.1", 443), timeout=2) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=domain) as tls:
                return bool(tls.getpeercert())
    except (OSError, ssl.SSLError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--migrate", action="store_true")
    parser.add_argument("domain")
    parser.add_argument("--extra-client-stdin", action="store_true")
    args = parser.parse_args()
    if not (DIRECT_DIR / "managed").is_file():
        raise RuntimeError("Only this project's managed 3x-ui installation can be migrated")
    if args.extra_client_stdin and not args.migrate:
        parser.error("--extra-client-stdin requires --migrate")
    rows = inbounds()
    target = [row for row in rows if row[2] == 443]
    source = [row for row in rows if row[2] == 10443]
    if len(target) > 1 or len(source) > 1:
        raise RuntimeError("Duplicate direct inbounds; review manually")
    if target:
        validate(target[0], args.domain)
        if not tls_ready(args.domain):
            raise RuntimeError("Port 443 exists but TLS or its listener is unhealthy")
        print("Managed VLESS/TCP+TLS on port 443 is healthy")
        return
    if not source:
        raise RuntimeError("No managed direct inbound on 443 or legacy 10443")
    _, settings, stream = validate(source[0], args.domain, legacy=True)
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 443)) == 0:
            raise RuntimeError("Port 443 is occupied by another service")
    if args.check:
        print("Managed legacy port 10443 is healthy; port 443 is free for migration")
        return

    selected = settings["clients"][0]["id"]
    if args.extra_client_stdin:
        extra = str(uuid.UUID(sys.stdin.readline().strip()))
        if all(client["id"] != extra for client in settings["clients"]):
            settings["clients"].append({"id": extra, "email": "imported-client", "enable": True})
        selected = extra
    stream["tlsSettings"]["alpn"] = ["h2", "http/1.1"]
    payload = {
        "enable": True, "remark": "vpn-stack-direct-tcp-443", "listen": "",
        "port": 443, "protocol": "vless", "expiryTime": 0, "total": 0,
        "settings": settings, "streamSettings": stream,
        "sniffing": {"enabled": False, "destOverride": []},
    }
    api = credentials(args.domain)
    created_id = None
    try:
        api("POST", "/add", payload)
        for _ in range(30):
            found = [row for row in inbounds() if row[2] == 443]
            if len(found) == 1:
                created_id, _, _ = validate(found[0], args.domain)
            if created_id and tls_ready(args.domain):
                break
            time.sleep(1)
        else:
            raise RuntimeError("Port 443 TLS did not become ready")
        link = (f"vless://{selected}@{args.domain}:443?"
                + urllib.parse.urlencode({"type": "tcp", "security": "tls", "sni": args.domain,
                                          "alpn": "h2,http/1.1", "fp": "chrome"})
                + "#" + urllib.parse.quote("vpn-stack-direct-tcp-443"))
        output = DIRECT_DIR / "client.txt"
        output.write_text(link + "\n")
        output.chmod(0o600)
        write_client(args.domain, 443, selected)
    except Exception:
        if created_id is not None:
            try:
                api("POST", f"/del/{created_id}")
            except Exception:
                print("Warning: port 443 rollback needs manual review", file=sys.stderr)
        raise
    print("VLESS/TCP+TLS is ready on port 443; legacy 10443 remains available")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, sqlite3.Error, RuntimeError) as exc:
        print(f"3x-ui port migration failed: {exc}", file=sys.stderr)
        raise SystemExit(1)

