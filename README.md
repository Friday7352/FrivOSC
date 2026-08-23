# FrivOSC

FrivOSC connects VRChat to [Frivo](https://github.com/Friday7352/Frivo). It
runs on the computer you play VRChat on, and it is what lets Frivo see your
VRChat microphone and write to your VRChat chatbox.

It is an optional companion. Frivo works without it; you only need FrivOSC
if you want the VRChat features.

## Why it exists

VRChat only speaks OSC to `127.0.0.1` — its own computer. It will not send
to another machine, and it will not listen to one. That is fine when Frivo
and VRChat share a PC, and impossible when they do not.

FrivOSC sits on the VRChat PC, where that loopback traffic already is, and
talks to Frivo over HTTP instead — which crosses machines happily.

```
VRChat  --OSC-->  FrivOSC  --HTTP-->  Frivo     your mute state
VRChat  <--OSC--  FrivOSC  <--HTTP--  Frivo     chatbox messages
```

Because of that, there are no ports to open, no launch options to set, and
nothing to configure in VRChat beyond turning OSC on.

## What it does

**Mute-synced dictation.** Frivo can start and stop dictation to match your
VRChat microphone — mute yourself in VRChat and dictation stops, unmute and
it starts. Clicking the mic button in Frivo still works exactly as it always
did; this only means it is no longer the only way.

**Chatbox.** Frivo's replies can appear in your VRChat chatbox. FrivOSC
handles VRChat's 144-character limit, the page counters, and the rate limit
that VRChat applies to chatbox messages.

## Install FrivOSC

Install it on the computer that runs VRChat — not on the Frivo server, if
those are different machines.

1. Download **FrivOSCSetup.exe** from the latest GitHub release.
2. Run setup.
3. When asked, enter the address of your Frivo server. If Frivo runs on this
   same computer, leave it as `https://localhost:5000`. Use **Test** to
   check it before continuing.
4. In VRChat, turn on **OSC** in the Options menu. FrivOSC has nothing to
   listen to until you do.

Setup installs a small private Python environment and registers FrivOSC to
start when you sign in. There is nothing to download afterwards.

## Firewall

None needed, on either computer.

FrivOSC only makes outgoing connections, and Windows allows those by
default. It listens on `127.0.0.1` for VRChat, and loopback traffic is never
filtered. It reaches Frivo on the port Frivo already accepts connections on.

If you were previously using a `--osc=` launch option in VRChat to point it
at another machine, remove it. FrivOSC replaces that, and the launch option
would send VRChat's output away from the computer FrivOSC is listening on.

## Checking it works

Open the FrivOSC shortcut. It shows whether the service is running, whether
VRChat is being heard, and whether Frivo is reachable, and lets you correct
the Frivo address without editing anything by hand.

From a terminal, `frivosc_service.py --check` answers the same questions:

    "C:\Program Files\FrivOSC\.venv\Scripts\python.exe" ^
      "C:\Program Files\FrivOSC\frivosc_service.py" --check

## Updating

Run the installer again over an existing install. It closes the FrivOSC
window first if one is open — including one sitting in the notification
area — because Windows will not replace a running executable and the update
would otherwise fail partway through on a locked file. The window is asked
to close before it is killed, so its tray icon goes with it. Settings in
`config.json` are kept.

## Settings

Settings live in `C:\ProgramData\FrivOSC\config.json`, alongside the log
and `status.json`. The status file also carries the microphone state and a
count of relayed chatbox messages, which is what the window's two indicator
lights are reading.  The status file is how the FrivOSC window knows whether
the connection to Frivo is up: the service writes what it sees there every
couple of seconds, and the window reads it rather than testing the
connection a second way of its own. It is rewritten constantly and deleted
on a clean stop — there is nothing in it worth keeping.

| Key | Default | What it is |
| --- | --- | --- |
| `frivo_url` | — | Where Frivo is, e.g. `https://192.168.1.50:5000` |
| `stop_on_close` | `false` | Closing the window stops the relay instead of hiding it to the notification area |
| `listen_port` | `9001` | Where VRChat sends its OSC output |
| `vrchat_send_port` | `9000` | Where VRChat listens, for chatbox messages |
| `verify_tls` | `false` | See below |
| `ca_cert` | — | Path to Frivo's `ca.crt`, to turn verification on |
| `poll_seconds` | `0.5` | How often to check Frivo for chatbox messages |
| `heartbeat_seconds` | `5` | How often to re-report mute state unchanged |

Restart FrivOSC after editing the file — settings are read at startup.

### About `verify_tls`

Frivo serves HTTPS using a certificate it generated for itself, which no
other computer has any reason to trust, so certificate verification is off
by default. Point `ca_cert` at Frivo's `ca.crt` to turn it on.

Worth being clear about what this does and does not do: Frivo has no
authentication of any kind, so anything that can reach it can use it,
verified certificate or not. Both are intended for a private network. Do not
expose Frivo to the internet.

## Privacy

FrivOSC holds no API keys, no conversation history, and no audio. It knows
one address and two port numbers. Everything it sends to Frivo is your
mute state; everything it receives is text Frivo already decided to send.

## Uninstall

Use **Installed apps** in Windows Settings, or the FrivOSC uninstaller in
its install folder. It removes the program, its startup task, and its
shortcut. You can keep your settings for a future reinstall.

Frivo, VRChat, and any Python you already had are untouched.

## Running from source

FrivOSC needs only Python 3.9 or newer. There is nothing to install — the
service imports the standard library only, which is why `requirements.txt`
is empty.

    python frivosc_service.py --set-url https://192.168.1.50:5000
    python frivosc_service.py

## Tests

    pwsh -NoProfile -File tests/test-install-logic.ps1

Covers the installer logic that can lose data or delete the wrong folder.
See `tests/README.md`.

## License

MIT. See [LICENSE](LICENSE).
