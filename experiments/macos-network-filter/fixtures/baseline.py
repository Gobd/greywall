#!/usr/bin/env python3
"""Loopback-only traffic fixture. This is a baseline, NOT an enforcement test."""
import functools
import http.server
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]

class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        data = self.request.recv(64)
        self.request.sendall(data)

class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


def find_installed_executable(name, candidates):
    """Finder apps have a minimal PATH; inspect known installations, not shell RCs."""
    found = shutil.which(name)
    if found:
        return found
    for candidate in candidates:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def main():
    bun = find_installed_executable("bun", ["~/.bun/bin/bun", "/opt/homebrew/bin/bun",
                                           "~/.local/bin/bun", "~/bin/bun"])
    git = find_installed_executable("git", ["/usr/bin/git", "/opt/homebrew/bin/git"])
    if not bun or not git:
        missing = ", ".join(name for name, path in [("bun", bun), ("git", git)] if not path)
        raise RuntimeError("Existing executable(s) not found: " + missing +
                           "; nothing will be installed. Check PATH or the supported installation locations.")
    print("Using existing Bun:", bun, flush=True)
    print("Using existing Git:", git, flush=True)
    temp_root = ROOT / ".build" / "tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key in list(env):
        if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy") or key.startswith("GIT_CONFIG"):
            del env[key]
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
    servers = []
    try:
        with tempfile.TemporaryDirectory(prefix="network-fixture-", dir=temp_root) as directory:
            directory = Path(directory)
            repository = directory / "repo.git"
            empty_template = directory / "empty-template"
            empty_template.mkdir()
            subprocess.run([git, "init", "--bare", "--template=" + str(empty_template), str(repository)],
                           env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            subprocess.run([git, "--git-dir=" + str(repository), "update-server-info"], env=env, check=True)
            http_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
                    functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory)))
            servers.append(http_server)
            tcp = socketserver.ThreadingTCPServer(("127.0.0.1", 0), TCPHandler)
            servers.append(tcp)
            udp = socketserver.ThreadingUDPServer(("127.0.0.1", 0), UDPHandler)
            servers.append(udp)
            for server in servers:
                threading.Thread(target=server.serve_forever, daemon=True).start()
            http_url = "http://127.0.0.1:" + str(http_server.server_port)
            print("LOCAL TRAFFIC FIXTURE: response checks only; correlate with provider logs for filtering.", flush=True)
            print("Harness-like root PID:", os.getpid(), flush=True)
            subprocess.run([bun, "-e", 'const r = await fetch(process.argv[1]); if (!r.ok) process.exit(1); console.log("Bun HTTP:", r.status);', http_url + "/repo.git/HEAD"],
                           env=env, check=True, timeout=10)
            subprocess.run([git, "-c", "credential.helper=", "ls-remote", http_url + "/repo.git"],
                           env=env, check=True, timeout=10)
            print("Git HTTP: reached loopback repository", flush=True)
            # A grandchild opens raw TCP/UDP sockets, with no proxy support.
            subprocess.run(["/bin/sh", "-c", '"$1" "$2" "$3" "$4"; result=$?; exit "$result"',
                            "fixture", sys.executable, str(Path(__file__).with_name("raw_sockets.py")),
                            str(tcp.server_address[1]), str(udp.server_address[1])],
                           env=env, check=True, timeout=10)
            print("PASS: Bun, Git, raw TCP and UDP responses. Provider interception must be verified separately.", flush=True)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
