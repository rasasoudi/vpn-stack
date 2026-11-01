#!/usr/bin/env python3
"""OpenVPN via-file authentication against vpnctl's password hashes."""
import hashlib
import hmac
import json
import sys


def verify_password(password: str, entry: dict) -> bool:
    try:
        actual = hashlib.scrypt(password.encode(), salt=bytes.fromhex(entry["salt"]),
                                n=16384, r=8, p=1, maxmem=64 * 1024 * 1024)
        return hmac.compare_digest(actual, bytes.fromhex(entry["hash"]))
    except (ValueError, KeyError, TypeError, MemoryError):
        return False


def main() -> int:
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            username = stream.readline().rstrip("\r\n")
            password = stream.readline().rstrip("\r\n")
        if not username or len(username) > 64 or not password or len(password) > 1024:
            return 1
        with open("/etc/vpn-stack/users.json", encoding="utf-8") as stream:
            entry = json.load(stream).get(username)
        if not entry:
            return 1
        return 0 if verify_password(password, entry) else 1
    except (OSError, ValueError, KeyError, IndexError, TypeError, MemoryError):
        return 1


if __name__ == "__main__":
    sys.exit(main())

