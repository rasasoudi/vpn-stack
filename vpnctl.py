#!/usr/bin/env python3
"""Manage credentials and client profiles for the three VPN modes."""
import argparse
import getpass
import grp
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile

BASE = Path("/etc/vpn-stack")
USERS = BASE / "users.json"
PASSWD = BASE / "ocpasswd"
SETTINGS = BASE / "settings.json"
NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")


def atomic_write(path: Path, data: bytes, mode: int, gid: int = 0) -> None:
    fd, name = tempfile.mkstemp(prefix=".vpn-stack-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        os.fchown(fd, 0, gid)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def manage_user(action: str, username: str, generate: bool = False,
                allow_short_password: bool = False,
                password_stdin: bool = False) -> None:
    if not NAME.fullmatch(username):
        raise SystemExit("Username must use 1-64 letters, digits, _, . or -")
    users = json.loads(USERS.read_text())
    if action == "add":
        if generate:
            password = secrets.token_urlsafe(24)
            confirm = password
        elif password_stdin:
            password = sys.stdin.readline().rstrip("\r\n")
            confirm = sys.stdin.readline().rstrip("\r\n")
        else:
            password = getpass.getpass("VPN password: ")
            confirm = getpass.getpass("Confirm VPN password: ")
        minimum = 4 if allow_short_password else 12
        if not minimum <= len(password) <= 1024 or password != confirm:
            raise SystemExit(f"Passwords must match and be {minimum}-1024 characters")
        if len(password) < 12:
            print("Warning: short VPN passwords are vulnerable to guessing", file=sys.stderr)
        salt = os.urandom(16)
        digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1,
                                maxmem=64 * 1024 * 1024)
        users[username] = {"salt": salt.hex(), "hash": digest.hex()}
        fd, temp = tempfile.mkstemp(prefix=".ocpasswd-", dir=BASE)
        os.close(fd)
        try:
            shutil.copyfile(PASSWD, temp)
            os.chmod(temp, 0o600)
            subprocess.run(["ocpasswd", "-c", temp, username],
                           input=password + "\n" + password + "\n", text=True,
                           stdout=subprocess.DEVNULL, check=True)
            old = PASSWD.read_bytes()
            os.replace(temp, PASSWD)
            try:
                atomic_write(USERS, (json.dumps(users, sort_keys=True) + "\n").encode(),
                             0o640, grp.getgrnam("nogroup").gr_gid)
            except Exception:
                atomic_write(PASSWD, old, 0o600)
                raise
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        print(f"User {username} is ready for OpenVPN UDP, OpenVPN TCP, and ocserv")
        if generate:
            credential_file = BASE / "clients" / f"{username}.credentials"
            atomic_write(credential_file,
                         f"username={username}\npassword={password}\n".encode(), 0o600)
            print(f"Initial credentials: {credential_file} (delete after secure retrieval)")
    elif action == "delete":
        if username not in users:
            raise SystemExit("Unknown VPN user")
        del users[username]
        old = PASSWD.read_bytes()
        lines = [line for line in old.splitlines(keepends=True)
                 if not line.startswith((username + ":").encode())]
        atomic_write(PASSWD, b"".join(lines), 0o600)
        try:
            atomic_write(USERS, (json.dumps(users, sort_keys=True) + "\n").encode(),
                         0o640, grp.getgrnam("nogroup").gr_gid)
        except Exception:
            atomic_write(PASSWD, old, 0o600)
            raise
        print(f"User {username} removed; disconnect existing sessions separately")


def profile(mode: str) -> None:
    settings = json.loads(SETTINGS.read_text())
    domain = settings["domain"]
    if mode == "auto":
        connection = (f"remote {domain} {settings['udp_port']} udp\n"
                      f"remote {domain} {settings['tcp_port']} tcp\n")
    else:
        port = settings[f"{mode}_port"]
        proto = "udp" if mode == "udp" else "tcp-client"
        connection = f"proto {proto}\nremote {domain} {port}\n"
    ca = (BASE / "pki/ca.crt").read_text()
    crypt = (BASE / "pki/tls-crypt.key").read_text()
    content = ("client\ndev tun\n" + connection +
               "nobind\nremote-cert-tls server\nsetenv CLIENT_CERT 0\nauth-user-pass\nauth-nocache\n"
               "tls-version-min 1.2\ndata-ciphers AES-256-GCM:AES-128-GCM\n"
               "verb 3\n<ca>\n" + ca + "</ca>\n<tls-crypt>\n" + crypt + "</tls-crypt>\n")
    target = BASE / "clients" / f"{mode}.ovpn"
    atomic_write(target, content.encode(), 0o600)
    print(target)


def status() -> None:
    failed = False
    for service in ("vpn-stack-firewall", "openvpn-server@udp", "openvpn-server@tcp", "ocserv"):
        result = subprocess.run(["systemctl", "is-active", "--quiet", service], check=False)
        active = result.returncode == 0
        print(f"{service}: {'active' if active else 'FAILED'}")
        failed |= not active
    forward = Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() == "1"
    print(f"IPv4 forwarding: {'on' if forward else 'FAILED'}")
    failed |= not forward
    settings = json.loads(SETTINGS.read_text())
    print(f"ocserv address: https://{settings['domain']}:{settings['ocserv_port']}")
    print(f"OpenVPN profiles: {BASE / 'clients/auto.ovpn'}, {BASE / 'clients/udp.ovpn'}, {BASE / 'clients/tcp.ovpn'}")
    try:
        resolved = {item[4][0] for item in socket.getaddrinfo(
            settings["domain"], None, family=socket.AF_INET, type=socket.SOCK_STREAM)}
        addresses = subprocess.check_output(["ip", "-o", "-4", "addr", "show"], text=True)
        local = {line.split()[3].split("/")[0] for line in addresses.splitlines()}
        dns_ok = bool(resolved) and resolved <= local
    except (OSError, IndexError):
        resolved, dns_ok = set(), False
    print(f"Domain A records on this host: {'OK' if dns_ok else 'FAILED'} ({', '.join(sorted(resolved)) or 'none'})")
    failed |= not dns_ok
    firewall = (BASE / "firewall.nft").read_text()
    egress = re.search(r"\bsnat to ([0-9.]+)", firewall)
    print(f"VPN IPv4 egress: {egress.group(1) if egress else 'outbound interface default'}")
    cert = settings.get("cert")
    if cert:
        result = subprocess.run(["openssl", "x509", "-in", cert, "-checkend", "604800", "-noout"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        print(f"ocserv certificate (>7 days): {'OK' if result.returncode == 0 else 'FAILED'}")
        failed |= result.returncode != 0
        hostname = subprocess.run(["openssl", "x509", "-in", cert, "-noout", "-checkhost", settings["domain"]],
                                  capture_output=True, text=True, check=False)
        name_ok = "does match certificate" in hostname.stdout
        print(f"ocserv certificate hostname: {'OK' if name_ok else 'FAILED'}")
        failed |= not name_ok
    if failed:
        raise SystemExit(1)


def main() -> None:
    if os.geteuid() != 0:
        raise SystemExit("Run as root")
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    user = sub.add_parser("user")
    user.add_argument("action", choices=["add", "delete"])
    user.add_argument("username")
    user.add_argument("--generate", action="store_true", help="Generate a password in a root-only file")
    user.add_argument("--allow-short-password", action="store_true",
                      help="Explicitly accept a 4-11 character VPN password (unsafe)")
    user.add_argument("--password-stdin", action="store_true",
                      help="Read password and confirmation from stdin instead of the terminal")
    prof = sub.add_parser("profile")
    prof.add_argument("mode", choices=["auto", "udp", "tcp"])
    sub.add_parser("status")
    args = parser.parse_args()
    if args.command == "user":
        if args.generate and args.action != "add":
            parser.error("--generate applies only to user add")
        if args.allow_short_password and args.action != "add":
            parser.error("--allow-short-password applies only to user add")
        if args.password_stdin and (args.action != "add" or args.generate):
            parser.error("--password-stdin applies only to user add without --generate")
        manage_user(args.action, args.username, args.generate,
                    args.allow_short_password, args.password_stdin)
    elif args.command == "profile":
        profile(args.mode)
    else:
        status()


if __name__ == "__main__":
    main()

