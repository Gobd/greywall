#!/usr/bin/env python3
"""Raw socket grandchild used by baseline.py; never connects outside loopback."""
import os
import socket
import sys

payload = b"greywall-local-probe"
print("Raw socket grandchild PID:", os.getpid())
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3) as tcp:
    tcp.sendall(payload)
    received = b""
    while len(received) < len(payload):
        chunk = tcp.recv(len(payload) - len(received))
        if not chunk:
            raise RuntimeError("TCP server closed early")
        received += chunk
    if received != payload:
        raise RuntimeError("Unexpected TCP echo")
print("Raw TCP: reached loopback server")
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(3)
    udp.sendto(payload, ("127.0.0.1", int(sys.argv[2])))
    received, _ = udp.recvfrom(128)
    if received != payload:
        raise RuntimeError("Unexpected UDP echo")
print("Raw UDP: reached loopback server")
