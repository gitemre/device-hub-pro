"""Security checks for the agent (spike). Needs DHP_BIND and DHP_TOKEN in the
environment and DHP_IFADDRS pointing at a JSON list saved from GET /ifaddrs
(kept outside the repo). Prints results without any address or token.

  (a) the server answers on the tunnel address;
  (b) it does NOT answer on any other address the phone has (Wi-Fi LAN first), 2 s timeout;
  (c) a request without the token, or with a wrong one, gets 401 and does nothing.
"""
import http.client
import json
import os
import socket
import time

from agentclient import Agent

bind = os.environ["DHP_BIND"]
addrs = json.load(open(os.environ["DHP_IFADDRS"]))
port = 8765

# (a)
a = Agent()
s, body, dt = a.request("GET", "/status")
print(f"(a) tunnel address: HTTP {s} in {dt*1000:.0f} ms")

# (c)
for label, headers in (("no token", {}), ("wrong token", {"X-DeviceHubPro-Token": "0" * 64}),
                       ("empty token", {"X-DeviceHubPro-Token": ""})):
    for method, path, body in (("GET", "/status", None), ("POST", "/tap", {"x": 1, "y": 1}),
                               ("POST", "/stop", {})):
        a2 = Agent(token=None)
        s, b, dt = a2.request(method, path, body, headers=headers)
        print(f"(c) {label:12s} {method} {path:8s} -> HTTP {s} {b.decode()[:40]}")
# still alive after the unauthorised /stop attempts
print("(c) still running after unauthorised /stop:", Agent().request("GET", "/status")[0] == 200)

# (b) every other address of the phone, IPv4 first
def try_connect(host, scope=None):
    fam = socket.AF_INET6 if ":" in host else socket.AF_INET
    sock = socket.socket(fam, socket.SOCK_STREAM)
    sock.settimeout(2)
    t0 = time.perf_counter()
    try:
        if fam == socket.AF_INET6:
            addr = socket.getaddrinfo(host + (f"%{scope}" if scope else ""), port, fam, socket.SOCK_STREAM)[0][4]
        else:
            addr = (host, port)
        sock.connect(addr)
        try:
            sock.sendall(b"GET /status HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            data = sock.recv(100)
        except OSError:
            data = b""
        return "CONNECTED (answer starts %r)" % data[:15]
    except socket.timeout:
        return "timeout"
    except OSError as e:
        return "error %s" % (e.strerror or e)
    finally:
        sock.close()


import subprocess
for x in addrs:
    if x["name"] == "en0" and ":" not in x["addr"]:
        r = subprocess.run(["ping", "-c", "2", "-t", "4", x["addr"]], capture_output=True, text=True)
        loss = [l for l in r.stdout.splitlines() if "packet loss" in l]
        print("(b) control: ICMP ping of the phone's Wi-Fi IPv4 address from this Mac:", loss[0].split(",")[2].strip() if loss else "no answer")

seen = set()
results = []
for x in addrs:
    name, addr = x["name"], x["addr"]
    clean = addr.split("%")[0]
    if clean == bind or (name, clean) in seen or name == "lo0":
        continue
    seen.add((name, clean))
    scope = None
    if clean.startswith("fe80"):
        scope = os.environ.get("DHP_MAC_LAN_IF", "en1")  # link-local: through the Mac's LAN interface
    results.append((name, "v6" if ":" in clean else "v4", clean.split(":")[0][:4] if ":" in clean else "-", try_connect(clean, scope)))
for name, fam, kind, res in results:
    print(f"(b) phone {name:6s} {fam} {'(prefix '+kind+')' if kind != '-' else '':15s} port {port}: {res}")
print("(b) any non-tunnel address connected:", any(r[3].startswith("CONNECTED") for r in results))
