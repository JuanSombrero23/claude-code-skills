<#
================================================================================
  Open-Sessions.ps1
================================================================================
  WHAT THIS IS
    Launcher for the session-curator skill's "launch" mode. Opens one Windows
    Terminal TAB per Claude Code session, in the CURRENT WT window, each tab
    running `claude --resume <id>` in that session's recorded cwd. Tab titles are
    set to the session's customTitle (Claude Code also re-titles the tab to the
    session name once it loads).

  WHY IT EXISTS
    Crash recovery + "open my sessions" requests. The user reviews the session index,
    picks which ids to reopen, and this turns them into tabs in one shot — no
    copy-pasting a stack of `claude --resume` commands by hand.

  HARD-WON INVOCATION DETAIL (confirmed live 2026-06-10 — do NOT regress this)
    wt.exe argument quoting from PowerShell is treacherous:
      * Passing the command via PowerShell's `--%` stop-parsing token sends the
        QUOTES LITERALLY into wt's `-d` value. wt then treats the path as
        relative and prepends the process cwd, producing an invalid doubled path
        like  <home>\"<home>""  (error 0x8007010b,
        "Could not access starting directory"). The errored tab opens but no
        shell launches.
      * The RELIABLE method is to build a string[] and SPLAT it to the call
        operator (`& wt.exe @args`). PowerShell 7 quotes each argv element
        correctly. This script uses that method. Do NOT refactor to `--%` or a
        single interpolated string.
      * wt splits its commandline on `;`. So the per-tab command must contain NO
        semicolon. We set the working dir with wt's own `-d <dir>` instead of a
        `cd '<dir>'; claude ...` chain — sidestepping the `;` split entirely.

  USAGE
    .\Open-Sessions.ps1 -Ids a35d9f41,0bc14919      # open these (id prefix ok)
    .\Open-Sessions.ps1 -Ids <id> -DryRun           # print the wt calls, launch nothing
    .\Open-Sessions.ps1 -Ids <id> -Window 0         # target WT window (0 = current/MRU)

  CREATED
    2026-06-10. Part of session-curator. See SKILL.md "Launch mode".
================================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Ids,
    [string] $IndexPath = (Join-Path $HOME '.claude\skills\session-curator\.session-index.json'),
    [string] $Window    = '0',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    throw "wt.exe (Windows Terminal) not found on PATH. Tabs need Windows Terminal; fall back to Start-Process for separate windows."
}
if (-not (Test-Path $IndexPath)) {
    throw "Session index not found at $IndexPath. Run Extract-SessionIndex.ps1 first."
}

# `pwsh -File Open-Sessions.ps1 -Ids a,b,c` passes "a,b,c" as ONE string (a -File
# quirk — comma array-binding only works in-session). Split on commas so both the
# comma form and the space-separated form (-Ids a b c) work. (smoke test 2026-06-10)
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$idx = Get-Content $IndexPath -Raw | ConvertFrom-Json
$opened = 0
$missing = @()

foreach ($wanted in $Ids) {
    $s = $idx.sessions | Where-Object { $_.id -eq $wanted } | Select-Object -First 1
    if (-not $s) { $s = $idx.sessions | Where-Object { $_.id -like "$wanted*" } | Select-Object -First 1 }
    if (-not $s) { $missing += $wanted; Write-Host "MISSING  $wanted (not in index)" -ForegroundColor Yellow; continue }

    $title = if ($s.customTitle) { $s.customTitle } else { "session-$($s.id.Substring(0,[math]::Min(8,$s.id.Length)))" }

    # Build argv as an array and splat — see HARD-WON INVOCATION DETAIL above.
    $wtArgs = @('-w', $Window, 'new-tab', '--title', $title)
    if ($s.cwd) { $wtArgs += @('-d', $s.cwd) }
    $wtArgs += @('pwsh', '-NoExit', '-Command', "claude --resume $($s.id)")

    if ($DryRun) {
        $shown = ($wtArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        Write-Host "DRYRUN   wt.exe $shown"
    } else {
        & wt.exe @wtArgs
        if ($LASTEXITCODE -eq 0) { $opened++; Write-Host "OPENED   $title  [$($s.cwd)]" -ForegroundColor Green }
        else { Write-Host "FAILED   $title  (wt exit $LASTEXITCODE)" -ForegroundColor Red }
    }
}

Write-Host ""
if ($DryRun) { Write-Host "Dry run — $($Ids.Count) session(s) would be opened." -ForegroundColor Cyan }
else { Write-Host "$opened tab(s) opened, $($missing.Count) missing." -ForegroundColor Cyan }
