#!/usr/bin/env python3
"""Exercise the documented curl pipe using a real, locally trusted HTTPS server."""
import functools
import hashlib
import http.server
import io
import os
from pathlib import Path
import platform
import ssl
import subprocess
import tarfile
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        cert, key = root / "cert.pem", root / "key.pem"
        config = root / "openssl.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                          "[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
                          "basicConstraints=critical,CA:TRUE\n")
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "1", "-subj", "/CN=localhost",
            "-config", str(config),
            "-keyout", str(key), "-out", str(cert),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        arch = "aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"
        system = "macos" if platform.system() == "Darwin" else "linux"
        archive = root / f"tmux-link-{system}-{arch}.tar.gz"
        with tarfile.open(archive, "w:gz") as package:
            files = {
                "./bin/agent": b"#!/bin/sh\necho download-agent\n",
                "./bin/center": b"#!/bin/sh\necho download-center\n",
                "./share/tmux-link/README.md": b"fixture\n",
            }
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.mode = 0o755 if "/bin/" in name else 0o644
                info.size = len(data)
                package.addfile(info, io.BytesIO(data))
        sums = root / "SHA256SUMS"
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        sums.write_text(f"{digest}  {archive.name}\n")
        (root / "install.sh").write_bytes((ROOT / "install.sh").read_bytes())
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"https://localhost:{server.server_port}"
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        env["CURL_CA_BUNDLE"] = str(cert)
        prefix = root / "installed"
        try:
            # Positional parameters avoid shell interpolation of paths or credentials.
            subprocess.run([
                "bash", "-o", "pipefail", "-c",
                'curl -fsSL "$1/install.sh" | sh -s -- --download-base-url "$1" --prefix "$2"',
                "test", base, str(prefix),
            ], check=True, env=env)
            assert (prefix / "bin/tmux-link-agent").exists()
            assert not (prefix / "bin/tmux-link-center").exists()
            assert subprocess.check_output([str(prefix / "bin/tmux-link-agent")]).strip() == b"download-agent"
            # Upgrade must replace the inode, allowing existing processes to keep running.
            previous = (prefix / "bin/tmux-link-agent").stat().st_ino
            subprocess.run(["sh", str(ROOT / "install.sh"), "--download-base-url", base,
                            "--prefix", str(prefix)], check=True, env=env)
            assert (prefix / "bin/tmux-link-agent").stat().st_ino != previous
            upgraded = (prefix / "bin/tmux-link-agent").stat().st_ino
            # A fetched archive with mismatched checksum must leave the installation intact.
            archive.write_bytes(archive.read_bytes() + b"corruption")
            rejected = subprocess.run(["sh", str(ROOT / "install.sh"), "--download-base-url", base,
                                      "--prefix", str(prefix)], env=env)
            assert rejected.returncode != 0
            assert (prefix / "bin/tmux-link-agent").stat().st_ino == upgraded
            assert subprocess.check_output([str(prefix / "bin/tmux-link-agent")]).strip() == b"download-agent"
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        print("HTTPS curl pipe, default client role, upgrade and corruption checks passed")


if __name__ == "__main__":
    main()
