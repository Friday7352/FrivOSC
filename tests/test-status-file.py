#!/usr/bin/env python3
"""The service publishes status.json; the launcher window reads it.

This test runs both halves against each other, because the bug it exists
to prevent was exactly a disagreement between two things that each looked
correct on their own: the service reported "Connected to Frivo" in its log
while the launcher, making its own HTTPS request, said "Cannot reach
Frivo". There is now one source of truth, and this checks that the reader
gets back what the writer wrote — including the awkward cases: a missing
file, a stale one left behind by a dead process, and a corrupt one.

The launcher's reader is not duplicated here. It is extracted from
FrivOSC-Launcher.ps1 at run time, so this test fails if the real function
changes shape.

Usage:  python3 tests/test-status-file.py
Needs:  pwsh (or powershell.exe) on PATH.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAUNCHER = os.path.join(ROOT, "FrivOSC-Launcher.ps1")
SERVICE = os.path.join(ROOT, "frivosc_service.py")


def find_powershell():
    for name in ("pwsh", "powershell.exe", "powershell"):
        found = shutil.which(name)
        if found:
            return found
    print("SKIP: no PowerShell found; the reader half cannot be exercised.")
    sys.exit(0)


def build_probe(directory):
    """Wrap the launcher's own Read-FrivOSCStatus in a script that prints it."""
    with open(LAUNCHER, encoding="utf-8-sig") as handle:
        source = handle.read()
    start = source.index("function Read-FrivOSCStatus {")
    end = source.index("function Test-FrivoReachable")
    function = source[start:end]

    probe = os.path.join(directory, "probe.ps1")
    with open(probe, "w", encoding="utf-8") as handle:
        handle.write(
            "Set-StrictMode -Version Latest\n"
            "$ErrorActionPreference = 'Stop'\n"
            "$StatusPath = $env:FRIVOSC_TEST_STATUS\n\n"
            + function
            + "\n$s = Read-FrivOSCStatus\n"
            "[pscustomobject]@{ Present = $s.Present; Fresh = $s.Fresh;\n"
            "  Connected = $s.Connected; Detail = $s.Detail; FrivoUrl = $s.FrivoUrl;\n"
            "  ListenPort = $s.ListenPort; VrchatPackets = $s.VrchatPackets;\n"
            "  Muted = $s.Muted } | ConvertTo-Json -Compress\n"
        )
    return probe


def main():
    shell = find_powershell()
    workspace = tempfile.mkdtemp(prefix="frivosc-status-")
    os.environ["FRIVOSC_DATA"] = os.path.join(workspace, "data")

    spec = importlib.util.spec_from_file_location("frivosc_service", SERVICE)
    service = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(service)

    probe = build_probe(workspace)
    environment = dict(os.environ, FRIVOSC_TEST_STATUS=service.STATUS_PATH)

    def read_back():
        result = subprocess.run(
            [shell, "-NoProfile", "-File", probe],
            capture_output=True, text=True, env=environment,
        )
        if result.returncode != 0:
            raise SystemExit("The launcher's reader failed to run:\n"
                             + result.stdout + result.stderr)
        return json.loads(result.stdout.strip())

    failures = []

    def check(name, condition, got=None):
        print(("PASS  " if condition else "FAIL  ") + name
              + ("" if condition else "   got=%s" % (got,)))
        if not condition:
            failures.append(name)

    service.clear_status()
    state = read_back()
    check("nothing published yet is not reported as connected",
          state["Present"] is False and state["Fresh"] is False, state)

    service.write_status(running=True, frivo_url="https://192.168.1.248:5000",
                         connected=True, detail="", listen_port=9001,
                         vrchat_send_port=9000, vrchat_packets=7, muted=True)
    state = read_back()
    check("a fresh report reads as connected", state["Fresh"] and state["Connected"], state)
    check("the address survives the round trip",
          state["FrivoUrl"] == "https://192.168.1.248:5000", state)
    check("the listen port survives the round trip", state["ListenPort"] == 9001, state)
    check("the VRChat packet count survives the round trip",
          state["VrchatPackets"] == 7, state)
    check("mute state arrives as a real boolean", state["Muted"] is True, state)

    service.write_status(running=True, frivo_url="https://x:5000", connected=False,
                         detail="timed out", listen_port=9001, vrchat_send_port=9000,
                         vrchat_packets=0, muted=None)
    state = read_back()
    check("a failed connection reads as not connected", state["Connected"] is False, state)
    check("the reason is carried through for the window to show",
          state["Detail"] == "timed out", state)
    check("unknown mute state stays unknown", state["Muted"] is None, state)

    # A status file left behind by a process that has since died. Without the
    # freshness check the window would keep claiming a live connection.
    stale = json.load(open(service.STATUS_PATH))
    stale["updated_at"] = time.time() - 120
    stale["connected"] = True
    json.dump(stale, open(service.STATUS_PATH, "w"))
    state = read_back()
    check("a stale report is not treated as current",
          state["Present"] and not state["Fresh"], state)

    with open(service.STATUS_PATH, "w") as handle:
        handle.write("{ this is not json")
    state = read_back()
    check("a corrupt file does not crash the window", state["Fresh"] is False, state)

    json.dump({"connected": True}, open(service.STATUS_PATH, "w"))
    state = read_back()
    check("a report with no timestamp is not treated as current",
          state["Present"] and state["Fresh"] is False, state)

    print()
    if failures:
        print("FAILED: " + ", ".join(failures))
        return 1
    print("All status-file assertions passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
