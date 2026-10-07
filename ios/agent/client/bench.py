"""Latency benchmark for the agent (spike). 20 repetitions each.
DHP_BIND and DHP_TOKEN in the environment; prints statistics only.

  python3 bench.py [status tap swipe type orientation screenshot volume home]
"""
import os
import statistics
import sys
import time

from agentclient import Agent

HOST = "com.devicehubpro.agent.host"
N = int(os.environ.get("BENCH_N", "20"))


def stats(label, xs, unit="ms", scale=1000.0):
    xs = sorted(x * scale for x in xs)
    p = lambda q: xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]
    print(f"{label:34s} n={len(xs):2d} min {xs[0]:7.1f}  median {statistics.median(xs):7.1f}  p90 {p(0.9):7.1f}  max {xs[-1]:7.1f} {unit}")


def status(a):
    xs = [a.request("GET", "/status")[2] for _ in range(N)]
    stats("GET /status (keep-alive)", xs)
    ys = []
    for _ in range(N):
        b = Agent()
        ys.append(b.request("GET", "/status")[2])  # includes TCP connect
    stats("GET /status (new connection)", ys)


def launch_host(a):
    a.json("POST", "/launch", {"bundleId": HOST})
    time.sleep(1.5)


def tap(a):
    launch_host(a)
    rtt, deliver, visible = [], [], []
    for i in range(N):
        x, y = (100, 700) if i % 2 == 0 else (290, 760)
        c0 = a.json("GET", "/probe?x=195&y=200")[1]
        st, body, dt = a.json("POST", "/tap", {"x": x, "y": y})
        rtt.append(dt)
        t0 = body["t0"]
        # first changed probe (on-device screenshot each; each probe costs ~0.15-0.2 s)
        t_first = None
        p0 = time.perf_counter()
        for _ in range(20):
            c = a.json("GET", "/probe?x=195&y=200")[1]
            if (c["r"], c["g"], c["b"]) != (c0["r"], c0["g"], c0["b"]):
                t_first = time.perf_counter() - p0 + dt
                break
        visible.append(t_first if t_first is not None else float("nan"))
        h = a.json("GET", "/host")[1]
        try:
            deliver.append(float(h["touchTime"]) - t0)
        except ValueError:
            pass
        time.sleep(0.2)
    stats("POST /tap RTT", rtt)
    stats("tap() call -> touch received (phone clock)", deliver)
    ok = [v for v in visible if v == v]
    stats("tap request -> first changed frame", ok)
    print(f"  (changed frame seen in {len(ok)}/{N} runs; upper bound: one on-device probe ~{0.2*1000:.0f} ms)")


def swipe(a):
    launch_host(a)
    xs = []
    for i in range(N):
        xs.append(a.json("POST", "/swipe", {"x1": 200, "y1": 600, "x2": 200, "y2": 300, "duration": 0.25})[2])
    stats("POST /swipe (300 pt, 0.25 s)", xs)


def typing(a):
    launch_host(a)
    h = a.json("GET", "/host")[1]
    fx, fy = h["fieldFrame"][:2]
    a.json("POST", "/tap", {"x": fx, "y": fy})
    time.sleep(1)
    xs = []
    for i in range(N):
        s, b, dt = a.json("POST", "/type", {"text": "abcdefghij0123456789", "bundleId": HOST})
        assert s == 200, b
        xs.append(dt)
    stats("POST /type (20 chars)", xs)
    h = a.json("GET", "/host")[1]
    print(f"  field now holds {len(h['field'])} characters (expected {20*N})")


def orientation(a):
    launch_host(a)
    setl, get, back, ok = [], [], [], 0
    for i in range(N):
        s, b, dt = a.json("POST", "/orientation", {"value": "landscapeLeft"})
        setl.append(dt)
        time.sleep(0.6)
        s, b, dt = a.json("GET", "/orientation")
        get.append(dt)
        ok += b.get("value") == "landscapeLeft"
        s, b, dt = a.json("POST", "/orientation", {"value": "portrait"})
        back.append(dt)
        time.sleep(0.6)
    stats("POST /orientation landscapeLeft", setl)
    stats("GET /orientation", get)
    stats("POST /orientation portrait", back)
    print(f"  read back landscapeLeft in {ok}/{N}; final: {a.json('GET', '/orientation')[1]}")


def screenshot(a):
    for fmt in ("png", "jpeg&q=0.5"):
        path = "/screenshot" if fmt == "png" else f"/screenshot?format={fmt}"
        sizes, ts = [], []
        t_all = time.perf_counter()
        for _ in range(N):
            s, b, dt = a.request("GET", path)
            assert s == 200
            sizes.append(len(b)); ts.append(dt)
        total = time.perf_counter() - t_all
        stats(f"GET {path}", ts)
        print(f"  {N/total:.2f} frames/s sequential, mean {statistics.mean(sizes)/1024:.0f} KiB/frame")


def volume(a):
    v0 = a.json("GET", "/status")[1]["volume"]
    first, second = ("volumeDown", "volumeUp") if v0 >= 0.99 else ("volumeUp", "volumeDown")
    xs = []
    for i in range(N // 2):
        for name in (first, second):
            xs.append(a.json("POST", "/button", {"name": name})[2])
            time.sleep(0.3)
    stats("POST /button volume up/down", xs)
    v1 = a.json("GET", "/status")[1]["volume"]
    print(f"  volume {v0:.3f} -> {v1:.3f}")


def home(a):
    xs = [a.json("POST", "/button", {"name": "home"})[2] for _ in range(N)]
    stats("POST /button home", xs)


if __name__ == "__main__":
    a = Agent(timeout=60)
    which = sys.argv[1:] or ["status", "tap", "type", "swipe", "orientation", "screenshot", "volume", "home"]
    for name in which:
        print(f"--- {name}")
        globals()[{"type": "typing"}.get(name, name)](a)
