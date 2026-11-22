#!/usr/bin/env python3
"""Exercise the shipped nginx route policy over real client-authenticated TLS."""
import base64
import hashlib
import http.client
import http.server
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

DEPLOY = Path(__file__).resolve().parents[1] / "deploy"


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.paths.append(self.path)
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()

    def log_message(self, *args):
        pass


def run(directory):
    def command(*args):
        return subprocess.check_output(args, cwd=directory)

    def cert_tool(*args):
        return command(sys.executable, DEPLOY / "device-cert.py", *args)

    def identity(label, authority):
        command("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-out", label + ".key")
        command("openssl", "pkey", "-in", label + ".key", "-pubout", "-out", label + ".pub")
        cert_tool("issue", authority, label, label + ".pub", label + ".der")
        command("openssl", "x509", "-inform", "DER", "-in", label + ".der", "-out", label + ".pem")

    cert_tool("init", "ca")
    cert_tool("init", "foreign-ca")
    identity("owner", "ca")
    identity("spare", "ca")
    identity("foreign", "foreign-ca")
    command("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
            "-keyout", "server.key", "-out", "server.pem")
    acl = directory / "authorized-routes.map"
    acl.write_bytes(cert_tool("grants", "owner.der", "primary", "Build"))
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    upstream.paths = []
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    mapping = (DEPLOY / "nginx-tmux-link-map.conf").read_text().replace(
        "/etc/nginx/tmux-link/authorized-routes.map", str(acl))
    broker_proxy = directory / "broker-proxy.conf"
    broker_proxy.write_text((DEPLOY / "nginx-tmux-link-broker-proxy.conf").read_text().replace(
        "127.0.0.1:7682", f"127.0.0.1:{upstream.server_port}"))
    location = (DEPLOY / "nginx-tmux-link.conf").read_text().replace(
        "/etc/nginx/tmux-link/device-ca.pem", str(directory / "ca/device-ca.pem")
    ).replace("127.0.0.1:7682", f"127.0.0.1:{upstream.server_port}"
    ).replace("/etc/nginx/tmux-link/broker-proxy.conf", str(broker_proxy))
    nginx = os.environ.get("TMUX_LINK_TEST_NGINX", "nginx")
    config = directory / "nginx.conf"
    config.write_text(f"""
daemon off;
worker_processes 1;
pid {directory}/nginx.pid;
error_log {directory}/nginx.log;
events {{ worker_connections 64; }}
http {{
    access_log off;
    client_body_temp_path {directory}/body;
    proxy_temp_path {directory}/proxy;
    fastcgi_temp_path {directory}/fastcgi;
    uwsgi_temp_path {directory}/uwsgi;
    scgi_temp_path {directory}/scgi;
    {mapping}
    server {{
        listen 127.0.0.1:{port} ssl;
        ssl_certificate {directory}/server.pem;
        ssl_certificate_key {directory}/server.key;
        {location}
        location / {{ return 204; }}
    }}
}}
""")

    def request(path, device=None):
        ctx = ssl.create_default_context(cafile=str(directory / "server.pem"))
        if device:
            ctx.load_cert_chain(directory / (device + ".pem"), directory / (device + ".key"))
        conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=3, context=ctx)
        try:
            conn.request("GET", path, headers={
                "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
                "Sec-WebSocket-Key": base64.b64encode(os.urandom(16)).decode(),
            })
            return conn.getresponse().status
        finally:
            conn.close()

    proc = subprocess.Popen([nginx, "-e", "stderr", "-p", str(directory), "-c", str(config)], cwd=directory)
    try:
        for _ in range(50):
            if proc.poll() is not None:
                raise RuntimeError("nginx exited before the test started")
            try:
                assert request("/") == 204
                break
            except ConnectionRefusedError:
                time.sleep(0.05)
        assert request("/tmux-link") == 403
        assert request("/tmux-link/primary", "spare") == 403
        assert request("/tmux-link/build", "owner") == 403
        assert request("/tmux-link/other", "owner") == 403
        try:
            assert request("/tmux-link", "foreign") in (400, 403)
        except ssl.SSLError:
            pass  # Rejection during the handshake also protects the upstream.
        assert upstream.paths == []
        for path in ("/tmux-link", "/tmux-link/primary", "/tmux-link/Build"):
            assert request(path, "owner") == 101
        assert upstream.paths == ["/tmux-link", "/tmux-link/primary", "/tmux-link/Build"]
        assert request("/tmux-link/pair") == 403
        assert request("/tmux-link/pair", "spare") == 403
        assert request("/tmux-link/session/" + "a" * 32) == 403
        assert request("/tmux-link/pair", "owner") == 101
        assert request("/tmux-link/session/" + "a" * 32, "owner") == 101
        assert request("/tmux-link/register") == 101
        assert request("/tmux-link/tunnel") == 101
        acl.write_text("")
        proc.send_signal(signal.SIGHUP)
        for _ in range(50):
            if request("/tmux-link", "owner") == 403:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("revoked certificate kept its route access after reload")
        assert request("/tmux-link/pair", "owner") == 403
        assert request("/tmux-link/session/" + "a" * 32, "owner") == 403
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        upstream.shutdown()
        upstream.server_close()
    print("mTLS edge verified: public sibling, trust, route grants, WebSocket upgrade, revocation")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as temp:
        run(Path(temp))
