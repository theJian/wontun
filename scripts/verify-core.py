#!/usr/bin/env python3
"""Verify the packaged app works after relocation, with only loopback traffic."""
import argparse
import http.server
import json
from pathlib import Path
import socket
import shutil
import os
import subprocess
import tempfile
import threading


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=root / "build/Wontun.app")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="wontun-bundled-core-") as temp:
        # The copy has a different path, including spaces; no installed core is used.
        app = Path(temp) / "Relocated Wontun.app"
        shutil.copytree(args.app, app)
        executable = app / "Contents/MacOS/wontun-core"
        sing_box = app / "Contents/MacOS/sing-box"
        data = Path(temp) / "data"
        environment = {**os.environ, "PATH": "/usr/bin:/bin"}
        process = subprocess.Popen([str(executable), "--data-dir", str(data)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def request(command, **fields):
            process.stdin.write(json.dumps(dict(command=command, **fields)) + "\n")
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            assert response["ok"], response.get("error")
            return response["result"]

        try:
            fresh = request("snapshot")
            assert fresh["state"]["settings"]["core_path"] == ""
            assert (app / "Contents/Resources/Licenses/sing-box.txt").is_file()
            assert (app / "Contents/Resources/Licenses/GPL-3.0.txt").is_file()
            # Validate generated outbound configurations against the actual core schema.
            links = [
                "socks5://127.0.0.1:1080#SOCKS",
                "http://u:p@example.com:8080#HTTP",
                "https://u:p@example.com:443#HTTPS",
                "ss://YWVzLTEyOC1nY206c2VjcmV0@example.com:8388#SS",
                "trojan://secret@example.com:443#Trojan",
                "vless://550e8400-e29b-41d4-a716-446655440000@example.com:443?security=tls&type=ws&path=%2Fws#VLESS",
                "hy2://secret@example.com:443?sni=example.com#HY2",
                "tuic://550e8400-e29b-41d4-a716-446655440000:secret@example.com:443#TUIC",
                "anytls://secret@example.com:443#AnyTLS",
            ]
            for link in links:
                result = request("import", content=link)
                request("select", id=result["state"]["profiles"][-1]["id"])
                config = request("preview")["config"]
                path = Path(temp) / "check.json"
                path.write_text(config)
                check = subprocess.run([str(sing_box), "check", "-c", str(path)], capture_output=True, text=True)
                assert check.returncode == 0, (link.split("#")[-1], check.stderr)
            result = request("import", content=json.dumps({"type": "direct", "tag": "Loopback test"}))
            request("select", id=result["state"]["profiles"][-1]["id"])
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            settings = result["state"]["settings"]
            settings.update(mixed_port=port, bypass_private=False)
            request("settings", settings=settings)

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    payload = b"wontun-proxy-ok"
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                def log_message(self, *_):
                    pass

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                started = request("start")
                assert started["status"]["running"]
                target = f"http://127.0.0.1:{server.server_port}/"
                # curl ignores proxy for loopback by default; explicitly clear that bypass.
                proxied = subprocess.run(["/usr/bin/curl", "--fail", "--silent", "--noproxy", "", "--proxy", f"http://127.0.0.1:{port}", "--max-time", "5", target], capture_output=True)
                assert proxied.returncode == 0, proxied.stderr
                assert proxied.stdout == b"wontun-proxy-ok"
                stopped = request("stop")
                assert not stopped["status"]["running"]
                assert not (data / "runtime.json").exists()
                # EOF also stops a live core, as when the app exits unexpectedly.
                request("start")
                process.stdin.close()
                process.wait(timeout=8)
                assert process.returncode == 0
                assert not (data / "runtime.json").exists()
                with socket.socket() as probe:
                    assert probe.connect_ex(("127.0.0.1", port)) != 0
            finally:
                server.shutdown()
                server.server_close()
            print(f"PASS: relocated app with default bundled core and no Homebrew PATH; {len(links)} configurations; real HTTP proxy traffic; disconnect; cleanup on EOF")
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=8)


if __name__ == "__main__":
    main()
