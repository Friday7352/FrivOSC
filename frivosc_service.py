"""FrivOSC — the OSC bridge between VRChat and Frivo.

Runs on the PC that plays VRChat. VRChat only ever speaks OSC to
127.0.0.1, so a Frivo server on another machine cannot hear it and cannot
reach VRChat's chatbox. FrivOSC sits on the VRChat PC where that loopback
traffic already is, and talks to Frivo over HTTP instead — which crosses
machines happily, on a port Frivo already listens on.

Both directions go through here:

    VRChat  --OSC 9001-->  FrivOSC  --HTTP-->  Frivo    (mute state)
    VRChat  <--OSC 9000--  FrivOSC  <--HTTP--  Frivo    (chatbox text)

FrivOSC only ever makes outbound HTTP calls. It never listens on a network
port, so it needs no firewall rule and no elevation, and there is nothing
here for anyone else on the network to connect to.

It holds no API keys and no history. If this install is lost, nothing is
lost with it.

Standard library only, deliberately: the PC running VRChat is usually not
the PC with a Python toolchain set up, and every dependency is another way
for an install to fail on a machine nobody can debug remotely.
"""

import json
import os
import queue
import re
import signal
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.request

APP_NAME = "FrivOSC"
VERSION = "1.0.0"

try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass


# =============================================================================
# Paths and configuration
# =============================================================================
# ProgramData rather than the install folder: setup writes the Frivo address
# here while elevated, the service reads it while not, and Program Files is
# not writable by an ordinary user. Overridable for development.

def data_directory():
    override = os.environ.get("FRIVOSC_DATA")
    if override:
        return override
    if os.name == "nt":
        base = os.environ.get("ProgramData") or os.environ.get("APPDATA") or os.getcwd()
    else:
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, APP_NAME)


DATA_DIR = data_directory()
CONFIG_PATH = os.path.join(DATA_DIR, "config.json")
LOG_PATH = os.path.join(DATA_DIR, "frivosc.log")
# The launcher window reads this instead of making its own request to
# Frivo. Two different HTTP clients asking the same question gave two
# different answers — the service connected while PowerShell's
# Invoke-WebRequest refused the self-signed certificate — and the one
# that matters is the one actually doing the work.
STATUS_PATH = os.path.join(DATA_DIR, "status.json")

DEFAULT_CONFIG = {
    # Where Frivo is. Written by setup; "" means nothing is configured yet
    # and the service idles rather than guessing.
    "frivo_url": "",
    # VRChat's OSC defaults. Changing these is only necessary if VRChat was
    # started with a --osc= launch option using different ports.
    "vrchat_send_port": 9000,
    "listen_port": 9001,
    # Frivo serves HTTPS with a certificate it generated itself, which no
    # other machine has any reason to trust. Verification is therefore off
    # by default; point ca_cert at Frivo's ca.crt to turn it on. Note that
    # Frivo has no authentication either way, so this is not the thing
    # keeping a hostile LAN out — see the README.
    "verify_tls": False,
    "ca_cert": "",
    # How often to ask Frivo for pending chatbox messages.
    "poll_seconds": 0.5,
    # Resend mute state even when unchanged, so Frivo can tell "still
    # unmuted" from "FrivOSC died".
    "heartbeat_seconds": 5.0,
}


def load_config():
    config = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            config.update(json.load(handle))
    except FileNotFoundError:
        pass
    except Exception as exc:
        log(f"config.json could not be read ({exc}); using defaults")
    return config


def save_config(config):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)


_status_lock = threading.Lock()


def write_status(**fields):
    """Publish what the service currently knows, for the launcher to read.

    Written whole each time, through a temporary file, so the launcher can
    never catch a half-written document. Failures are ignored: a status file
    nobody can write is a cosmetic problem, and the bridge keeps running.
    """
    payload = {
        "version": VERSION,
        "pid": os.getpid(),
        # Wall clock rather than monotonic, because the reader is a different
        # process. Staleness is how the launcher tells "connected" from
        # "was connected before this process died".
        "updated_at": time.time(),
    }
    payload.update(fields)
    try:
        with _status_lock:
            os.makedirs(DATA_DIR, exist_ok=True)
            temporary = STATUS_PATH + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)
            os.replace(temporary, STATUS_PATH)
    except Exception:
        pass


def clear_status():
    try:
        os.remove(STATUS_PATH)
    except Exception:
        pass


_log_lock = threading.Lock()


def log(message):
    line = time.strftime("[%Y-%m-%d %H:%M:%S] ") + str(message)
    print(line, flush=True)
    try:
        with _log_lock:
            os.makedirs(DATA_DIR, exist_ok=True)
            # Truncate rather than rotate. This log is for "why did it stop
            # working", not an audit trail, and an unbounded file on someone
            # else's machine is worse than a short one.
            if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 1_000_000:
                os.replace(LOG_PATH, LOG_PATH + ".old")
            with open(LOG_PATH, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
    except Exception:
        # Logging must never be the reason the bridge stops relaying.
        pass


# =============================================================================
# OSC wire format
# =============================================================================
# Ported from Frivo's app.py rather than rewritten. The encoders and the
# chatbox pager were already working against real VRChat; this is the same
# code in the place that now owns it.

OSC_CHATBOX_LIMIT = 144
OSC_MIN_GAP_SECONDS = 1.5
OSC_MAX_GAP_SECONDS = 60.0
OSC_PAGE_SECONDS_SPEAKING = 1.6
OSC_PAGE_SECONDS_SILENT = 4.0


def osc_string(text):
    """OSC strings are null-terminated and padded to a multiple of 4 bytes."""
    data = text.encode("utf-8") + b"\0"
    padding = (4 - len(data) % 4) % 4
    return data + b"\0" * padding


def osc_message(address, *args):
    tags = ","
    payload = b""
    for arg in args:
        # bool first: in Python it's a subclass of int, so checking int
        # first would pack True as the integer 1 and VRChat would reject
        # the type tag.
        if isinstance(arg, bool):
            tags += "T" if arg else "F"
        elif isinstance(arg, int):
            tags += "i"
            payload += struct.pack(">i", arg)
        elif isinstance(arg, float):
            tags += "f"
            payload += struct.pack(">f", arg)
        else:
            tags += "s"
            payload += osc_string(str(arg))
    return osc_string(address) + osc_string(tags) + payload


def chatbox_pages(text, limit=OSC_CHATBOX_LIMIT):
    """
    Splits text into chatbox-sized pages, breaking at sentence ends where it
    can and word boundaries otherwise, so a page never ends mid-word.

    When there's more than one page each gets a " (1/3)" counter — without
    it a reader has no way to know the message they're looking at was the
    middle of something, since VRChat only ever shows the most recent one.
    """
    text = " ".join((text or "").split())
    if not text:
        return []
    if len(text) <= limit:
        return [text]

    def pack(budget):
        pages, current = [], ""
        # Two alternatives, not one: the first keeps end punctuation with
        # the sentence it closes, and the second catches a run of .!? that
        # isn't preceded by anything — a leading "!!!", or an ellipsis of
        # its own between two sentences. Without it the regex simply skips
        # over those characters and they vanish from the message.
        for sentence in re.findall(r"[^.!?]+[.!?]*|[.!?]+", text) or [text]:
            sentence = sentence.strip()
            while len(sentence) > budget:
                # One sentence longer than a whole page: break at the last
                # space that fits, or hard-cut if there isn't one.
                cut = sentence.rfind(" ", 0, budget + 1)
                if cut <= 0:
                    cut = budget
                if current:
                    pages.append(current)
                    current = ""
                pages.append(sentence[:cut].strip())
                sentence = sentence[cut:].strip()
            if not sentence:
                continue
            if not current:
                current = sentence
            elif len(current) + 1 + len(sentence) <= budget:
                current = f"{current} {sentence}"
            else:
                pages.append(current)
                current = sentence
        if current:
            pages.append(current)
        return pages

    pages = pack(limit)
    if len(pages) <= 1:
        return pages

    # Re-pack with room for the counter. Its width depends on the number of
    # pages, which depends on the packing — so pack, measure, pack again.
    # One pass is enough in practice; the loop guards the case where making
    # room for the suffix pushes the text into another page.
    #
    # The repacked list is adopted *before* the settled check, not after —
    # keeping the wider packing once the count happened to match is what
    # let a page come out at 150 characters with the counter attached.
    for _ in range(3):
        suffix = len(f" ({len(pages)}/{len(pages)})")
        repacked = pack(limit - suffix)
        settled = len(repacked) == len(pages)
        pages = repacked
        if settled:
            break
    total = len(pages)
    return [f"{p} ({i}/{total})" for i, p in enumerate(pages, 1)]


def osc_read_string(data, offset):
    """Reverse of osc_string(): read a null-terminated, 4-byte-padded string."""
    end = data.index(b"\0", offset)
    text = data[offset:end].decode("utf-8", errors="replace")
    consumed = end + 1 - offset
    padded = consumed + ((4 - consumed % 4) % 4)
    return text, offset + padded


def osc_parse_message(data):
    """
    Decodes a single incoming OSC message into (address, args). Anything
    that doesn't parse — malformed or truncated packets, blob arguments —
    comes back as ("", []) rather than raising: a listener on an open UDP
    port has to expect noise, and one bad packet shouldn't take it down.
    """
    try:
        address, offset = osc_read_string(data, 0)
        if not address.startswith("/") or offset >= len(data) or data[offset:offset + 1] != b",":
            return address, []
        tags, offset = osc_read_string(data, offset)
        args = []
        for tag in tags[1:]:
            if tag == "i":
                args.append(struct.unpack_from(">i", data, offset)[0])
                offset += 4
            elif tag == "f":
                args.append(struct.unpack_from(">f", data, offset)[0])
                offset += 4
            elif tag == "s":
                value, offset = osc_read_string(data, offset)
                args.append(value)
            elif tag == "T":
                args.append(True)
            elif tag == "F":
                args.append(False)
            elif tag in ("N", "I"):
                args.append(None)
            else:
                # Blob and other rarer tags aren't needed for avatar
                # parameters — stop rather than guess how much to skip.
                break
        return address, args
    except (ValueError, IndexError, struct.error, UnicodeError):
        return "", []


def clamp_page_seconds(value, default):
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return default
    return max(OSC_MIN_GAP_SECONDS, min(OSC_MAX_GAP_SECONDS, seconds))


# =============================================================================
# Listening to VRChat
# =============================================================================

class MuteWatcher:
    """
    Watches VRChat's OSC output for MuteSelf, the built-in avatar parameter
    that tracks the microphone.

    Binds 127.0.0.1 rather than 0.0.0.0. VRChat only ever sends to loopback,
    so accepting these packets from the network would widen the surface for
    no gain — and it is what keeps FrivOSC free of any firewall rule.
    """

    MUTE_ADDRESS = "/avatar/parameters/MuteSelf"

    def __init__(self, port):
        self.port = port
        self.muted = None
        self.updated_at = None
        self.packets = 0
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None

    def state(self):
        with self._lock:
            return self.muted, self.updated_at, self.packets

    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)

    def _run(self):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", self.port))
        except OSError as exc:
            log(f"Could not listen on UDP 127.0.0.1:{self.port}: {exc}")
            log("Another OSC application is probably already using that port.")
            return

        log(f"Listening for VRChat on 127.0.0.1:{self.port}")
        # A timeout instead of a blocking recvfrom, so the stop event is
        # noticed without closing the socket from another thread.
        sock.settimeout(1.0)
        try:
            while not self._stop.is_set():
                try:
                    data, _addr = sock.recvfrom(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    address, args = osc_parse_message(data)
                except Exception:
                    continue
                if address != self.MUTE_ADDRESS or not args:
                    continue
                muted = bool(args[0])
                with self._lock:
                    first = self.packets == 0
                    changed = muted != self.muted
                    self.muted = muted
                    self.updated_at = time.time()
                    self.packets += 1
                if first:
                    log("VRChat is talking to us.")
                if changed:
                    log(f"VRChat microphone: {'muted' if muted else 'unmuted'}")
        finally:
            sock.close()


# =============================================================================
# Talking to VRChat
# =============================================================================

class ChatboxSender:
    """
    Sends text to VRChat's chatbox, paged and paced.

    One queue and one worker, because VRChat rate-limits the chatbox: the
    pacing has to hold across separate messages, not just between the pages
    of one, or a second message arriving quickly gets the first one dropped.
    """

    def __init__(self, port):
        self.port = port
        self.queue = queue.Queue(maxsize=40)
        self._stop = threading.Event()
        self._thread = None
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)

    def send(self, text, speaking=True, sfx=True):
        """Queues text. Returns the page count, or 0 if there was nothing."""
        pages = chatbox_pages(text)
        if not pages:
            return 0
        page_seconds = OSC_PAGE_SECONDS_SPEAKING if speaking else OSC_PAGE_SECONDS_SILENT
        try:
            self.queue.put_nowait((pages, bool(sfx), float(page_seconds)))
        except queue.Full:
            raise RuntimeError("Too many messages queued for VRChat.")
        return len(pages)

    def _emit(self, message):
        self._sock.sendto(message, ("127.0.0.1", self.port))

    def _run(self):
        last_send = 0.0
        while not self._stop.is_set():
            try:
                pages, sfx, page_seconds = self.queue.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                for index, page in enumerate(pages):
                    wait = max(OSC_MIN_GAP_SECONDS, page_seconds)
                    gap = wait - (time.monotonic() - last_send)
                    if gap > 0:
                        # Interruptible, so a stop during a long paged
                        # message does not hang shutdown for a minute.
                        if self._stop.wait(gap):
                            return
                    more = index < len(pages) - 1
                    self._emit(osc_message("/chatbox/input", page, True, sfx))
                    self._emit(osc_message("/chatbox/typing", more))
                    last_send = time.monotonic()
            except Exception as exc:
                log(f"Chatbox send failed: {exc}")
            finally:
                self.queue.task_done()


# =============================================================================
# Talking to Frivo
# =============================================================================

class FrivoClient:
    """
    The only thing here that touches the network.

    Every call is outbound and short-lived. Frivo being unreachable is an
    expected state, not an error: the server may simply not be running yet,
    and this has to recover on its own when it comes back rather than
    needing FrivOSC restarted.
    """

    def __init__(self, base_url, verify_tls=False, ca_cert=""):
        self.base_url = (base_url or "").rstrip("/")
        self.context = None
        if self.base_url.startswith("https://"):
            if verify_tls and ca_cert:
                self.context = ssl.create_default_context(cafile=ca_cert)
            elif verify_tls:
                self.context = ssl.create_default_context()
            else:
                # Frivo signs its own certificate, so no other machine has
                # any reason to trust it. See the note in DEFAULT_CONFIG.
                self.context = ssl._create_unverified_context()

    def _request(self, method, path, payload=None, timeout=10):
        url = self.base_url + path
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        kwargs = {"timeout": timeout}
        if self.context is not None:
            kwargs["context"] = self.context
        with urllib.request.urlopen(request, **kwargs) as response:
            body = response.read().decode("utf-8", errors="replace")
        if not body:
            return {}
        try:
            return json.loads(body)
        except ValueError:
            return {}

    def hello(self):
        return self._request("POST", "/api/frivosc/hello", {
            "version": VERSION,
            "hostname": socket.gethostname(),
            "oscquery": False,
        })

    def report_state(self, muted):
        return self._request("POST", "/api/frivosc/state", {"muted": muted})

    def fetch_outbox(self):
        return self._request("GET", "/api/frivosc/outbox")

    def acknowledge(self, message_id, pages):
        return self._request("POST", "/api/frivosc/ack", {"id": message_id, "pages": pages})


# =============================================================================
# The bridge
# =============================================================================

class Bridge:
    """
    Ties the three pieces together and keeps running through everything a
    two-machine setup can do to it: Frivo restarting, VRChat closing, the
    network dropping, the user never configuring an address at all.

    Connection problems are logged once per transition rather than per
    attempt. At two polls a second, an unreachable server would otherwise
    produce a log nobody can read and a disk nobody expects to fill.
    """

    def __init__(self, config):
        self.config = config
        self.watcher = MuteWatcher(int(config.get("listen_port", 9001)))
        self.sender = ChatboxSender(int(config.get("vrchat_send_port", 9000)))
        self.client = FrivoClient(
            config.get("frivo_url", ""),
            verify_tls=bool(config.get("verify_tls", False)),
            ca_cert=config.get("ca_cert", ""),
        )
        self.poll_seconds = float(config.get("poll_seconds", 0.5))
        self.heartbeat_seconds = float(config.get("heartbeat_seconds", 5.0))
        self._stop = threading.Event()
        self._connected = None
        self._detail = ""
        self._reported_mute = "unset"
        self._last_heartbeat = 0.0
        self._last_status_write = 0.0
        # What the window shows instead of asking someone to read a log:
        # how many chatbox messages have come through, and when the last
        # one did. Wall clock, because a different process reads it.
        self._chatbox_total = 0
        self._chatbox_last = 0.0

    def stop(self):
        self._stop.set()

    def _note_connection(self, ok, detail=""):
        if ok == self._connected:
            return
        self._connected = ok
        self._detail = detail
        if ok:
            log(f"Connected to Frivo at {self.client.base_url}")
        else:
            log(f"Frivo is not reachable at {self.client.base_url} — {detail}")
            log("Still trying. This resolves itself when Frivo is running again.")
        # Published on the transition as well as on the timer below, so the
        # launcher window reflects a reconnect within a refresh rather than
        # within the publish interval.
        self._publish_status()

    def _publish_status(self, running=True):
        muted, _updated_at, packets = self.watcher.state()
        self._last_status_write = time.monotonic()
        write_status(
            running=running,
            frivo_url=self.client.base_url,
            connected=bool(self._connected),
            detail=self._detail,
            listen_port=self.watcher.port,
            vrchat_send_port=self.sender.port,
            vrchat_packets=packets,
            muted=muted,
            chatbox_total=self._chatbox_total,
            chatbox_last=self._chatbox_last,
        )

    def _push_state(self):
        muted, _updated_at, packets = self.watcher.state()
        # Nothing heard from VRChat yet means there is no state to report.
        # Reporting "unmuted" here would be a guess, and Frivo would act on
        # it by enabling dictation for a mic that may well be muted.
        if packets == 0:
            return
        due = (time.monotonic() - self._last_heartbeat) >= self.heartbeat_seconds
        if muted == self._reported_mute and not due:
            return
        try:
            self.client.report_state(muted)
            self._reported_mute = muted
            self._last_heartbeat = time.monotonic()
            self._note_connection(True)
        except Exception as exc:
            self._note_connection(False, str(exc))

    def _pump_outbox(self):
        try:
            response = self.client.fetch_outbox()
            self._note_connection(True)
        except Exception as exc:
            self._note_connection(False, str(exc))
            return

        for message in (response or {}).get("messages") or []:
            text = (message or {}).get("text") or ""
            if not text:
                continue
            try:
                pages = self.sender.send(
                    text,
                    speaking=bool(message.get("speaking", True)),
                    sfx=bool(message.get("sfx", True)),
                )
            except Exception as exc:
                log(f"Could not queue chatbox message: {exc}")
                continue
            # Acknowledged once queued, not once delivered. OSC is UDP with
            # no receipt, so "delivered" is not a thing anyone can observe —
            # and leaving it unacknowledged would have Frivo send it again.
            self._chatbox_total += 1
            self._chatbox_last = time.time()
            # Published straight away rather than on the next tick: the
            # window's "receiving" light is the whole point of counting.
            self._publish_status()

            try:
                if message.get("id"):
                    self.client.acknowledge(message["id"], pages)
            except Exception as exc:
                log(f"Could not acknowledge {message.get('id')}: {exc}")

    def run(self):
        if not self.client.base_url:
            log("No Frivo address is configured.")
            log(f"Set frivo_url in {CONFIG_PATH}, or run setup again.")
            self._connected = False
            self._detail = "no address configured"
            self._publish_status(running=False)
            return 1

        log(f"{APP_NAME} {VERSION}")
        log(f"Frivo: {self.client.base_url}")
        log(f"VRChat chatbox: 127.0.0.1:{self.sender.port}")

        self.watcher.start()
        self.sender.start()

        try:
            self.client.hello()
            self._note_connection(True)
        except Exception as exc:
            self._note_connection(False, str(exc))

        try:
            while not self._stop.is_set():
                self._push_state()
                self._pump_outbox()
                # Republished on a slow timer even when nothing changed. The
                # timestamp is what tells a reader this process is still
                # alive, so it has to keep moving.
                if (time.monotonic() - self._last_status_write) >= 2.0:
                    self._publish_status()
                self._stop.wait(self.poll_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            log("Stopping.")
            self.sender.stop()
            self.watcher.stop()
            clear_status()
        return 0


def run_diagnostics(config):
    """
    `--check` — answers the two questions support threads actually ask:
    can this reach Frivo, and is VRChat sending anything.
    """
    print(f"{APP_NAME} {VERSION}")
    print(f"Config:  {CONFIG_PATH}")
    print(f"Log:     {LOG_PATH}")
    print()

    url = config.get("frivo_url", "")
    print(f"Frivo address: {url or '(not set)'}")
    if url:
        client = FrivoClient(url, bool(config.get("verify_tls", False)), config.get("ca_cert", ""))
        try:
            reply = client.hello()
            print(f"  reachable — Frivo replied {reply or '{}'}")
        except Exception as exc:
            print(f"  NOT reachable — {exc}")
    print()

    listen_port = int(config.get("listen_port", 9001))
    print(f"Listening for VRChat on 127.0.0.1:{listen_port} for 10 seconds...")
    watcher = MuteWatcher(listen_port)
    watcher.start()
    try:
        for _ in range(10):
            time.sleep(1)
            muted, _at, packets = watcher.state()
            if packets:
                print(f"  heard VRChat — microphone is {'muted' if muted else 'unmuted'}")
                break
        else:
            print("  heard nothing.")
            print("  Check that OSC is enabled in VRChat's Options menu, and that")
            print("  VRChat is running on this same computer.")
    finally:
        watcher.stop()
    return 0


def main(argv):
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        print("Usage: frivosc_service.py [--check] [--set-url URL]")
        return 0

    config = load_config()

    if "--set-url" in argv:
        index = argv.index("--set-url")
        if index + 1 >= len(argv):
            print("--set-url needs an address, e.g. --set-url https://192.168.1.248:5000")
            return 1
        config["frivo_url"] = argv[index + 1].rstrip("/")
        save_config(config)
        print(f"Frivo address set to {config['frivo_url']}")
        return 0

    if "--check" in argv:
        return run_diagnostics(config)

    bridge = Bridge(config)

    # Windows stops this with a hard kill, which no handler survives — the
    # launcher's staleness check is what covers that case. This is for the
    # ordinary termination signals, where leaving a status file claiming a
    # live connection would be a lie the moment the process is gone.
    def handle_signal(_number, _frame):
        bridge.stop()

    for name in ("SIGTERM", "SIGINT", "SIGBREAK"):
        number = getattr(signal, name, None)
        if number is None:
            continue
        try:
            signal.signal(number, handle_signal)
        except (ValueError, OSError):
            # Not the main thread, or unsupported on this platform.
            pass

    return bridge.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
