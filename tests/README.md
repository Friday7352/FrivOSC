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

## Not covered

The WinForms wizard and launcher are not exercised. They need a stubbed
`System.Windows.Forms` to run off Windows, which is a larger harness than
this repo currently justifies. They are parse-checked instead:

    pwsh -NoProfile -Command "Get-ChildItem *.ps1,*.psm1 -Recurse | ForEach-Object { \
      \$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$e) > \$null; \
      if (\$e) { Write-Host \$_.Name } }"

The service itself is tested by running it against a mock Frivo and a mock
VRChat — see the end-to-end harness notes in the repository history.
