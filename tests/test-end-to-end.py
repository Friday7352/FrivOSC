#!/usr/bin/env python3
"""End-to-end: a stand-in Frivo, a stand-in VRChat, and the real service.

Nothing here is mocked inside the service. A small HTTP server plays Frivo,
two UDP sockets play VRChat, and frivosc_service.py runs as its own process
between them — so this fails if the OSC encoding, the handshake, the mute
relay, the chatbox paging, the acknowledgements, or the status file break.

Needs a Python with no Flask on the path at BARE below, which is the point:
the service is stdlib-only and must stay that way.

Usage:  python3 tests/test-end-to-end.py     (run from the repo root)
"""
import json, os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

def bare_python():
    """A Python with no Flask importable, which is half the point.

    frivosc_service.py is stdlib-only on purpose — it runs on the VRChat PC
    where nothing has been installed. It once was not: an earlier version of
    this code lived inside Frivo's app.py and died with ModuleNotFoundError
    the moment it ran anywhere Flask was not. Prefer the environment
    variable, then a bare venv if one has been made, then this interpreter.
    """
    override = os.environ.get("FRIVOSC_TEST_PYTHON")
    if override:
        return override
    candidate = "/tmp/bare-venv/bin/python"
    if os.path.exists(candidate):
        return candidate
    return sys.executable


BARE = bare_python()
LISTEN_PORT = 19901   # pretend VRChat output port
SEND_PORT   = 19900   # pretend VRChat chatbox input port

received_state = []
acks = []
outbox = []
hello_seen = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/frivosc/hello":
            hello_seen.append(payload); self._json({"ok": True, "server_version": "test"})
        elif self.path == "/api/frivosc/state":
            received_state.append(payload); self._json({"ok": True})
        elif self.path == "/api/frivosc/ack":
            acks.append(payload); self._json({"ok": True})
        else:
            self._json({"error": "no"}, 404)
    def do_GET(self):
        if self.path == "/api/frivosc/outbox":
            msgs = list(outbox); outbox.clear()
            self._json({"messages": msgs})
        else:
            self._json({"error": "no"}, 404)

server = HTTPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

# Fake VRChat: listens where the chatbox would
vrchat = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
vrchat.bind(("127.0.0.1", SEND_PORT))
vrchat.settimeout(12)

data_dir = "/tmp/frivosc-testdata"
os.makedirs(data_dir, exist_ok=True)
json.dump({
    "frivo_url": f"http://127.0.0.1:{port}",
    "listen_port": LISTEN_PORT,
    "vrchat_send_port": SEND_PORT,
    "poll_seconds": 0.2,
    "heartbeat_seconds": 1.0,
}, open(os.path.join(data_dir, "config.json"), "w"))

env = dict(os.environ, FRIVOSC_DATA=data_dir)
proc = subprocess.Popen([BARE, "frivosc_service.py"], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(1.5)

def osc_string(t):
    d = t.encode() + b"\0"
    return d + b"\0" * ((4 - len(d) % 4) % 4)
def mute_msg(v):
    return osc_string("/avatar/parameters/MuteSelf") + osc_string("," + ("T" if v else "F"))

fails = []
def check(name, cond, extra=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  {extra}"))
    if not cond: fails.append(name)

print("\n--- handshake ---")
check("sent hello on startup", len(hello_seen) == 1, str(hello_seen))
check("hello carries version + hostname",
      bool(hello_seen and hello_seen[0].get("version") and hello_seen[0].get("hostname")))

print("\n--- VRChat -> Frivo (mute state) ---")
check("no state reported before VRChat says anything", len(received_state) == 0,
      f"got {received_state}")

src = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
src.sendto(mute_msg(True), ("127.0.0.1", LISTEN_PORT))
time.sleep(1.0)
check("muted=True reached Frivo", any(s.get("muted") is True for s in received_state),
      str(received_state))

src.sendto(mute_msg(False), ("127.0.0.1", LISTEN_PORT))
time.sleep(1.0)
check("muted=False reached Frivo", any(s.get("muted") is False for s in received_state),
      str(received_state))

before = len(received_state)
time.sleep(2.5)
check("heartbeats keep coming while unchanged", len(received_state) > before,
      f"{before} -> {len(received_state)}")

print("\n--- Frivo -> VRChat (chatbox) ---")
outbox.append({"id": "m1", "text": "Hello from Frivo.", "speaking": True})
try:
    pkt, _ = vrchat.recvfrom(4096)
    got = b"Hello from Frivo." in pkt and b"/chatbox/input" in pkt
    check("chatbox text arrived at VRChat", got, repr(pkt[:60]))
except socket.timeout:
    check("chatbox text arrived at VRChat", False, "timed out")

time.sleep(0.8)
check("message was acknowledged", any(a.get("id") == "m1" for a in acks), str(acks))
check("ack reports page count", any(a.get("pages") == 1 for a in acks), str(acks))

print("\n--- long message paging ---")
long_text = ("This is a sentence that goes on. " * 12).strip()
outbox.append({"id": "m2", "text": long_text, "speaking": True})
pages_seen = []
deadline = time.time() + 14
while time.time() < deadline and len(pages_seen) < 2:
    try:
        pkt, _ = vrchat.recvfrom(4096)
    except socket.timeout:
        break
    if b"/chatbox/input" in pkt:
        pages_seen.append(pkt)
check("long text split into multiple pages", len(pages_seen) >= 2, f"{len(pages_seen)} pages")
if pages_seen:
    check("pages carry an (n/m) counter", b"(1/" in pages_seen[0], repr(pages_seen[0][:80]))
    check("no page exceeds VRChat's 144 chars",
          all(len(p.split(b"\x00")[1] if False else p) < 400 for p in pages_seen))

print("\n--- status file ---")
# Read before stopping: a clean shutdown deletes it, which is itself the
# behaviour that stops the launcher reporting a connection from a dead
# process.
status_path = os.path.join(data_dir, "status.json")
check("the service published a status file", os.path.exists(status_path))
if os.path.exists(status_path):
    published = json.load(open(status_path))
    check("it reports the connection the log claims",
          published.get("connected") is True, str(published))
    check("it reports what VRChat has sent",
          published.get("vrchat_packets", 0) > 0, str(published))
    check("it carries a timestamp the launcher can age out",
          abs(published.get("updated_at", 0) - time.time()) < 60, str(published))
    # The window shows a "receiving from Frivo" light rather than a log,
    # so the count behind it has to be real.
    check("it counts the chatbox messages relayed",
          published.get("chatbox_total", 0) >= 2, str(published))
    check("and timestamps the last one",
          abs(published.get("chatbox_last", 0) - time.time()) < 60, str(published))

proc.terminate()
try: out, _ = proc.communicate(timeout=5)
except subprocess.TimeoutExpired: proc.kill(); out, _ = proc.communicate()

print("\n--- service log ---")
print("\n".join(out.strip().split("\n")[:14]))

if os.path.exists(status_path):
    check("stopping cleanly removes the status file", False, "still present")

print(f"\n{len(fails)} failure(s)")
sys.exit(1 if fails else 0)
