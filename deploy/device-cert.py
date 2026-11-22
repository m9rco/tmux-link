#!/usr/bin/env python3
"""Issue per-device terminal certificates and render route grants using OpenSSL 3+."""
import argparse
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile


def openssl(*args):
    return subprocess.run(["openssl", *args], check=True, stdout=subprocess.PIPE).stdout


def init(directory):
    directory.mkdir(mode=0o700)
    try:
        openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-nodes", "-sha256", "-days", "3650", "-subj", "/CN=Tmux Link device CA",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout", directory / "device-ca.key", "-out", directory / "device-ca.pem")
    except BaseException:
        shutil.rmtree(directory)
        raise


def name(value):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value):
        raise argparse.ArgumentTypeError("use 1 to 64 letters, digits, underscores or hyphens")
    return value


def issue(directory, label, public_key, output):
    # Only accept an independently verified PUBLIC device key. The signing Mac
    # has no need for the private key used by the device to prove possession.
    openssl("pkey", "-pubin", "-in", public_key, "-pubcheck", "-noout")
    serial = format((1 << 126) | secrets.randbits(126), "X")
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        temp = Path(temp)
        ext = temp / "extensions"
        ext.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                       "extendedKeyUsage=clientAuth\nauthorityKeyIdentifier=keyid:always\n")
        cert = temp / "cert.pem"
        openssl("x509", "-new", "-force_pubkey", public_key, "-subj", "/CN=" + label,
                "-CA", directory / "device-ca.pem", "-CAkey", directory / "device-ca.key",
                "-set_serial", "0x" + serial, "-days", "365", "-sha256",
                "-extfile", ext, "-out", cert)
        openssl("verify", "-purpose", "sslclient", "-CAfile", directory / "device-ca.pem", cert)
        der = temp / "cert.der"
        openssl("x509", "-in", cert, "-outform", "DER", "-out", der)
        os.link(der, output)  # Publish complete contents without overwriting a prior enrollment.


def grants(cert, routes):
    line = openssl("x509", "-inform", "DER", "-in", cert, "-noout", "-serial").decode().strip()
    serial = line.split("=", 1)[1].upper()
    if not re.fullmatch(r"[0-9A-F]+", serial):
        raise ValueError("invalid certificate serial")
    for route in dict.fromkeys(routes):
        path = "/tmux-link(?:/primary)?" if route == "primary" else "/tmux-link/" + route
        # Quoted, case-sensitive regex: nginx's plain map strings are case-insensitive.
        print(f'"~^SUCCESS:{serial}:{path}$" 1;')


def main():
    os.umask(0o077)
    cli = argparse.ArgumentParser(description=__doc__)
    actions = cli.add_subparsers(dest="action", required=True)
    actions.add_parser("init").add_argument("ca_dir", type=Path)
    cmd = actions.add_parser("issue")
    cmd.add_argument("ca_dir", type=Path)
    cmd.add_argument("label", type=name)
    cmd.add_argument("public_key", type=Path)
    cmd.add_argument("output", type=Path)
    cmd = actions.add_parser("grants")
    cmd.add_argument("cert", type=Path)
    cmd.add_argument("routes", type=name, nargs="+")
    args = cli.parse_args()
    if args.action == "init":
        init(args.ca_dir)
    elif args.action == "issue":
        issue(args.ca_dir, args.label, args.public_key, args.output)
    else:
        grants(args.cert, args.routes)


if __name__ == "__main__":
    main()
