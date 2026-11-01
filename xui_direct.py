#!/usr/bin/env python3
"""Read-only check for the existing 3x-ui VLESS/TCP inbound on this host."""
import json
import sqlite3
import subprocess
import sys

DB = "file:/etc/x-ui/x-ui.db?mode=ro"
PORT = 10443


def main() -> int:
    try:
        db = sqlite3.connect(DB, uri=True)
        rows = db.execute(
            "select id, enable, port, protocol, stream_settings, settings "
            "from inbounds where port = ?", (PORT,)
        ).fetchall()
        db.close()
        matches = []
        for inbound_id, enabled, port, protocol, stream_raw, settings_raw in rows:
            stream = json.loads(stream_raw or "{}")
            settings = json.loads(settings_raw or "{}")
            if (enabled and protocol == "vless" and stream.get("network") == "tcp"
                    and stream.get("security") in {"none", "tls"}
                    and stream.get("tcpSettings", {}).get("header", {}).get("type", "none") == "none"
                    and settings.get("decryption") == "none"):
                matches.append((inbound_id, port, len(settings.get("clients", [])), stream.get("security")))
        if len(matches) != 1 or matches[0][2] < 1:
            print("No unique, enabled 3x-ui VLESS/TCP direct inbound with a client on port 10443", file=sys.stderr)
            return 1
        if subprocess.run(["systemctl", "is-active", "--quiet", "x-ui"], check=False).returncode:
            print("3x-ui service is not active", file=sys.stderr)
            return 1
        listeners = subprocess.check_output(["ss", "-H", "-lnt"], text=True)
        if not any(line.split()[3].endswith(f":{PORT}") for line in listeners.splitlines()):
            print("Direct TCP port is not listening", file=sys.stderr)
            return 1
        inbound_id, port, clients, security = matches[0]
        print(f"Existing 3x-ui direct TCP: inbound {inbound_id}, port {port}, {clients} client(s), security {security}; preserved")
        print("Obtain its client link from 3x-ui; credentials are not exported.")
        return 0
    except (OSError, sqlite3.Error, ValueError, TypeError, KeyError, IndexError,
            subprocess.CalledProcessError) as exc:
        print(f"3x-ui read-only check failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
