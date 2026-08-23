<#
    The launcher's window contract, checked against the source.

    This is a weaker kind of test than the rest of this folder and it says
    so up front: it reads the script rather than running it. WinForms cannot
    be exercised off Windows, and the behaviour it protects has already been
    got wrong once — closing the window with "keep running in the
    background" chosen simply made everything vanish, because the window was
    the only thing on screen and nothing took its place.

    So the invariants that were missing are pinned here. It cannot prove the
    tray works; it can prove nobody quietly removed the pieces that make it
    possible.

    Comments are stripped before matching, so a mention of ShowDialog in a
    comment explaining why it is not used does not count as using it.

    Usage:  pwsh -NoProfile -File tests/test-launcher-shape.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
$launcher = Join-Path (Split-Path -Parent $here) 'FrivOSC-Launcher.ps1'
$raw = Get-Content -LiteralPath $launcher -Raw

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    $errors | ForEach-Object { Write-Host ("  parse error: " + $_.Message) }
    exit 1
}

# Whitespace removed as well as comments, so the patterns below do not
# have to care whether someone wrote `$notify.Visible = $true` or
# `$notify.Visible=$true`.
$code = (($tokens |
    Where-Object { $_.Kind -ne 'Comment' } |
    ForEach-Object { $_.Text }) -join ' ') -replace '\s+', ''

$fails = @()
function Check([string] $Name, [bool] $Condition, $Got) {
    if ($Condition) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name   got=$Got"; $script:fails += $Name }
}

Write-Host '--- the window has to outlive its own close button ---'
Check 'the message loop is Application::Run' ($code -match 'Application\]::Run') 'not found'
Check 'and not ShowDialog, which ends when the form hides' `
    (-not ($code -match 'ShowDialog')) 'ShowDialog is being called'

Write-Host ''
Write-Host '--- the notification area ---'
Check 'a tray icon exists' ($code -match 'NotifyIcon') 'none'
Check 'it is shown' ($code -match '\$notify\.Visible=\$true') 'never made visible'
Check 'it can be reopened from' ($code -match 'Add_DoubleClick') 'no way back to the window'
Check 'it offers a real way to quit' ($code -match '\$script:Quitting=\$true') 'no quit path'
Check 'and it is disposed when the form finally closes' `
    ($code -match '\$notify\.Dispose\(\)') 'leaked into the tray after exit'

Write-Host ''
Write-Host '--- closing the window ---'
Check 'the close is cancelled rather than allowed through' `
    ($code -match '\$eventArgs\.Cancel=\$true') 'nothing cancels the close'
Check 'the window is hidden instead' ($code -match '\$form\.Hide\(\)') 'never hidden'
Check 'and only when the setting says to keep running' `
    ($code -match 'Test-FrivOSCStopOnClose') 'the setting is not consulted'

Write-Host ''
Write-Host '--- a second launcher ---'
# Now that closing leaves it in the tray, clicking the shortcut again is a
# normal thing to do. Two windows arguing about one service is not.
Check 'is stopped by a mutex' ($code -match 'if\(-not\$createdMutex\)') 'no guard'
Check 'and brings the first one forward' ($code -match 'showSignal') 'no signal'

Write-Host ''
Write-Host '--- getting out of the way of an update ---'
# The window can be sitting in the notification area holding
# FrivOSCHost.exe open, and Windows will not replace a running executable.
# Setup asks it to leave rather than killing it, so the tray icon goes
# with it instead of lingering as a ghost.
Check 'it listens for setup asking it to quit' `
    ($code -match 'FrivOSCLauncherQuit') 'setup has no way to ask'
Check 'and the signal is cleared at startup, not acted on stale' `
    ($code -match '\$quitSignal\.Reset\(\)') 'a leftover signal would quit it immediately'

Write-Host ''
Write-Host '--- failures have somewhere to land ---'
# Opened from a shortcut, so an unhandled error has no console. This is the
# same silence that made the setup wizard look like it did nothing at all.
Check 'errors are written to a log' ($code -match 'FrivOSC-Launcher\.log') 'no log'
Check 'and shown to the person' ($code -match 'MessageBox') 'fails silently'

Write-Host ''
if ($fails.Count) {
    Write-Host ("{0} failed: {1}" -f $fails.Count, ($fails -join ', '))
    exit 1
}
Write-Host '16 passed, 0 failed'
