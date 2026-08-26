#!/usr/bin/env python3
"""One version number, read by everything.

Before this, FrivOSC had four version literals and they already disagreed
— before a single release had shipped. The service said 1.1.0, the Inno
container said 1.0.0, the compiled host said 1.0.0.0, and the Apps &
features entry was hardcoded to "1.0". Nothing catches that; they are
literals that have to be edited together and silently do not have to
match.

Now there is a `VERSION` file at the repo root and four consumers read it:

  * `Install-FrivOSC.ps1`    — the Apps & features entry
  * `build/FrivOSC.iss`      — the Inno container's own version
  * `build/Build-FrivOSCInstaller.ps1` — generates the assembly attributes
  * `frivosc_service.py`     — what the log and Frivo are told

This checks each of them resolves to the same string, and that none of them
has quietly grown a literal again.

Usage:  python3 tests/test-version.py     (run from the repo root)
Needs:  pwsh or powershell for the PowerShell halves.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_PATH = os.path.join(ROOT, "VERSION")

failures = []


def check(name, condition, got=None):
    print(("  PASS  " if condition else "  FAIL  ") + name
          + ("" if condition else "   got=%s" % (got,)))
    if not condition:
        failures.append(name)


def find_powershell():
    for name in ("pwsh", "powershell.exe", "powershell"):
        found = shutil.which(name)
        if found:
            return found
    return None


def run_powershell(shell, script):
    result = subprocess.run([shell, "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return "ERROR: " + (result.stdout + result.stderr).strip()
    return result.stdout.strip()


def extract(path, start_marker, end_marker):
    with open(path, encoding="utf-8-sig") as handle:
        text = handle.read()
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


def main():
    print("--- the file itself ---")
    check("VERSION exists at the repo root", os.path.exists(VERSION_PATH), VERSION_PATH)
    if not os.path.exists(VERSION_PATH):
        return 1

    raw = open(VERSION_PATH, "rb").read()
    version = raw.decode("utf-8-sig").strip()
    check("it holds a version number", bool(re.match(r"^\d+(\.\d+){1,3}$", version)), version)
    # Inno's preprocessor reads this file as plain text. A BOM would end up
    # inside the version string and produce an installer with a mangled
    # name, so it must not be written with one.
    check("and no byte-order mark, which Inno would read as part of it",
          not raw.startswith(b"\xef\xbb\xbf"), "BOM present")

    print()
    print("--- nobody kept a private copy ---")
    # The exact failure this replaces: literals that must be edited together
    # and silently do not have to.
    literal = re.compile(r"\b\d+\.\d+\.\d+(\.\d+)?\b")
    # Comment markers per language, because they differ in the way that
    # matters here: `#` starts a comment in PowerShell but starts the
    # *preprocessor* in an .iss file — which is exactly where a version
    # literal would live. Treating them the same made this scan pass over
    # a reintroduced literal without noticing.
    comment_markers = {
        ".ps1": ("#",),
        ".iss": (";",),
        ".cs": ("//",),
    }
    for name in ("Install-FrivOSC.ps1", "build/FrivOSC.iss", "build/FrivOSCHost.cs"):
        path = os.path.join(ROOT, *name.split("/"))
        markers = comment_markers[os.path.splitext(path)[1]]
        with open(path, encoding="utf-8-sig") as handle:
            body = "\n".join(
                line for line in handle.read().splitlines()
                if not line.lstrip().startswith(markers)
            )
        found = []
        for line in body.splitlines():
            # Not every dotted number is an app version. Python releases and
            # loopback addresses both look like one, and both legitimately
            # appear in an installer.
            if re.search(r"python", line, re.IGNORECASE):
                continue
            for match in literal.finditer(line):
                value = match.group(0)
                if value in ("10.0",):            # MinVersion=10.0 is Windows
                    continue
                # An IPv4 address: four parts, none above 255.
                parts = value.split(".")
                if len(parts) == 4 and all(int(p) <= 255 for p in parts):
                    continue
                found.append(value)
        check("%s has no version literal" % name, not found, found)

    check("FrivOSC.iss reads the VERSION file",
          "FileRead" in open(os.path.join(ROOT, "build", "FrivOSC.iss"), encoding="utf-8").read(),
          "no FileRead")

    print()
    print("--- frivosc_service.py ---")
    # Exercised with a fake __file__ so both layouts are covered: the repo,
    # where VERSION sits one level above app/, and an install, where app.py
    # and VERSION are side by side.
    source = extract(os.path.join(ROOT, "frivosc_service.py"),
                     "def _read_version():", "VERSION = _read_version()")
    workspace = tempfile.mkdtemp(prefix="frivo-version-")

    def version_at(app_dir, version_dir):
        os.makedirs(app_dir, exist_ok=True)
        os.makedirs(version_dir, exist_ok=True)
        with open(os.path.join(version_dir, "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")
        namespace = {"os": os, "__file__": os.path.join(app_dir, "app.py")}
        exec(source, namespace)
        return namespace["_read_version"]()

    installed = os.path.join(workspace, "installed")
    check("finds it beside the service, the way it is installed",
          version_at(installed, installed) == version, "mismatch")

    repo = os.path.join(workspace, "repo")
    check("and one level up, as a fallback",
          version_at(os.path.join(repo, "sub"), repo) == version, "mismatch")

    empty = os.path.join(workspace, "empty", "app")
    os.makedirs(empty, exist_ok=True)
    namespace = {"os": os, "__file__": os.path.join(empty, "app.py")}
    exec(source, namespace)
    check("says unknown rather than crashing when it is missing",
          namespace["_read_version"]() == "unknown", namespace["_read_version"]())

    shell = find_powershell()
    if shell is None:
        print()
        print("SKIP: no PowerShell; the installer and build halves were not run.")
    else:
        print()
        print("--- Install-FrivOSC.ps1 ---")
        install_fn = extract(os.path.join(ROOT, "Install-FrivOSC.ps1"),
                             "function Get-FrivOSCVersion {", "$script:AppVersion = Get-FrivOSCVersion")
        # Planted two levels up, which is where the setup payload keeps it
        # relative to installer\Install.ps1.
        # FrivOSC's payload is flat — VERSION sits beside the script.
        payload = os.path.join(workspace, "payload")
        os.makedirs(payload, exist_ok=True)
        with open(os.path.join(payload, "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")
        # Written to a real script at the path Install.ps1 occupies, and
        # run as a file. The function locates VERSION relative to
        # $PSCommandPath, which only has a real value when a real script is
        # running — faking it in -Command tests nothing.
        def probe_at(directory):
            os.makedirs(directory, exist_ok=True)
            probe = os.path.join(directory, "probe.ps1")
            with open(probe, "w", encoding="utf-8") as handle:
                handle.write(install_fn + "\nGet-FrivOSCVersion\n")
            result = subprocess.run([shell, "-NoProfile", "-File", probe],
                                    capture_output=True, text=True)
            return result.stdout.strip()

        check("reads it from the setup payload",
              probe_at(payload) == version,
              probe_at(payload))

        # The repo layout too: Install.bat runs installer\Install.ps1 with
        # VERSION at the root, one level up.
        repo_like = os.path.join(workspace, "repo-like")
        os.makedirs(repo_like, exist_ok=True)
        with open(os.path.join(repo_like, "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")
        check("and from the repo, the way Install.bat runs it",
              probe_at(os.path.join(repo_like, "installer")) == version,
              probe_at(os.path.join(repo_like, "installer")))

        check("falls back to unknown instead of failing the install",
              probe_at(os.path.join(workspace, "nopayload")) == "unknown",
              probe_at(os.path.join(workspace, "nopayload")))

        print()
        print("--- build/Build-FrivOSCInstaller.ps1 ---")
        build_fns = extract(os.path.join(ROOT, "build", "Build-FrivOSCInstaller.ps1"),
                            "function Get-FrivOSCVersion {", "function Find-InnoSetupCompiler {")
        build_root = os.path.join(workspace, "build-ok")
        os.makedirs(build_root, exist_ok=True)
        with open(os.path.join(workspace, "build-ok", "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")
        prelude = "$root = '%s'; %s; " % (build_root.replace("'", "''"), build_fns)
        got = run_powershell(shell, prelude + "Get-FrivOSCVersion")
        check("the build script reads the same file", got == version, got)

        # csc and Inno both reject a malformed version with errors that say
        # nothing about this file, so it is rejected here instead.
        with open(os.path.join(workspace, "build-ok", "VERSION"), "w", encoding="utf-8") as handle:
            handle.write("next-release\n")
        got = run_powershell(shell, prelude + "Get-FrivOSCVersion")
        check("and refuses a version that is not a number", got.startswith("ERROR"), got)
        with open(os.path.join(workspace, "build-ok", "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")

        generated = os.path.join(workspace, "Version.generated.cs")
        run_powershell(shell, prelude + (
            "New-FrivOSCVersionSource -Version '%s' -Path '%s'"
            % (version, generated.replace("'", "''"))
        ))
        attributes = ""
        if os.path.exists(generated):
            attributes = open(generated, encoding="utf-8-sig").read()
        padded = ".".join((version.split(".") + ["0", "0", "0"])[:4])
        check("the assembly attributes are generated", bool(attributes), "no file")
        check("padded to the four parts .NET wants",
              'AssemblyFileVersion("%s")' % padded in attributes, attributes.strip())
        check("and the unpadded version is kept as the informational one",
              'AssemblyInformationalVersion("%s")' % version in attributes, attributes.strip())

    shutil.rmtree(workspace, ignore_errors=True)

    print()
    if failures:
        print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
        return 1
    print("Every consumer agrees on %s." % version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
