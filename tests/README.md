# Tests

    pwsh -NoProfile -File tests/test-install-logic.ps1

Runs on Linux or Windows. Nothing here touches the registry, the real
filesystem outside a temporary folder, or an actual install.

## test-install-logic.ps1

Lifts the pure functions out of `Install-FrivOSC.ps1` and runs them for
real. It covers the two places a mistake would be expensive:

**Ownership.** `Test-FrivOSCInstallOwnership` is the only thing standing
between the uninstaller and a recursive delete. The tests check that an
unrelated folder, a marker copied in from elsewhere, a marker belonging to
another product, and a corrupt marker are all refused — and that a corrupt
one returns `$false` rather than throwing.

**Config merge.** An update must not lose the Frivo address, a hand-edited
port, or a certificate path. The tests write a config, mutate it the way a
user would, run an update over the top, and check everything survives.

There is also a StrictMode check on `Find-InstalledPython`, which is the
class of bug that shipped in Frivo 1.1.2: a collection that comes back
empty, unwraps to `$null`, and throws when something reads `.Count` off it.
That test caught a real one here — `Join-Path` throws rather than returning
anything when its base path is empty, which it can be in a service context
with no `LocalAppData`.

## test-status-file.py

    python3 tests/test-status-file.py

The service publishes what it knows to `%ProgramData%\FrivOSC\status.json`
every couple of seconds; the launcher window reads that file rather than
making its own request to Frivo. This test runs both halves against each
other — and extracts the reader straight out of `FrivOSC-Launcher.ps1`, so
it fails if the real function changes shape.

It exists because of a bug where the two disagreed: the service logged
"Connected to Frivo" while the launcher, three inches above that log line,
said "Cannot reach Frivo". Both were doing what they were written to do —
Python's `ssl._create_unverified_context()` accepted Frivo's self-signed
certificate and PowerShell's `Invoke-WebRequest` did not. There is now one
source of truth, and this checks the awkward cases around it: no file, a
stale file left by a process that has died, a corrupt file, and a file
missing its timestamp. All of them must read as "not connected" rather
than throwing or guessing.

## test-end-to-end.py

    python3 tests/test-end-to-end.py

A stand-in Frivo (HTTP), a stand-in VRChat (two UDP sockets), and the real
`frivosc_service.py` running as its own process in between. Nothing inside
the service is mocked, so this covers the OSC wire format, the handshake,
the mute relay, the chatbox paging and its 144-character limit, the
acknowledgements, and the status file.

It runs the service under an interpreter with no Flask on the path —
`FRIVOSC_TEST_PYTHON` overrides which. That is deliberate: this code has to
run on the VRChat PC, where nothing has been installed.

## test-inno-discovery.ps1

    pwsh -NoProfile -File tests/test-inno-discovery.ps1

The build script installs Inno Setup itself when it is missing — winget
first, then the current release straight from jrsoftware.org's GitHub. The
discovery half of that is pure logic, so it is tested: an existing install
must be found (machine-wide, per-user, version 6 or 7, or via the registry)
and must never be installed over, and when both install routes fail the
error has to say where to get it by hand and that a new window is needed.

The functions are extracted from the build script at run time rather than
copied, so this fails if the real ones change shape. It caught a real bug
immediately: `Join-Path` throws on an empty base, and the candidate paths
were being built inside an array literal — evaluated before the guard that
was supposed to skip them. Same shape as the `Find-InstalledPython` bug in
FrivOSC.

## preview-icons.py

    python3 tests/preview-icons.py

Not a test — nothing here asserts anything. The launcher draws its
microphone and chatbox glyphs with GDI+ at run time rather than shipping
images, so the only way to see them is normally to install FrivOSC on
Windows. This redraws the same coordinates with Pillow and writes
`tests/icons.png`, which makes iterating on them possible from anywhere.

It is a hand port and can drift. Change the geometry in the launcher and
you have to change it here too, or it stops telling you the truth.

## Not covered

The WinForms wizard and launcher are not exercised. They need a stubbed
`System.Windows.Forms` to run off Windows, which is a larger harness than
this repo currently justifies — and `System.Drawing` has no Unix support at
all on .NET 8, so even the icon drawing cannot be executed here, which is
why `preview-icons.py` exists. They are parse-checked instead:

    pwsh -NoProfile -Command "Get-ChildItem *.ps1,*.psm1 -Recurse | ForEach-Object { \
      \$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$e) > \$null; \
      if (\$e) { Write-Host \$_.Name } }"

The service itself is covered by `test-end-to-end.py` above.
