<#
================================================================================
  Extract-SessionIndex.ps1
================================================================================

  WHAT THIS IS
    The data layer for the `session-curator` skill. Walks every Claude Code
    session transcript under ~/.claude/projects/*/*.jsonl, parses each one for
    compact per-session metadata (first prompt, last user prompt, last assistant
    reply, message counts, timestamps, custom title, cwd, branch, end-state),
    computes temporal analytics (active minutes, gaps, days span, intensity,
    rhythm), detects fork lineage and duplicate-session candidates, and writes
    the result as a single JSON file the skill (and its subagents) read.

  WHY IT EXISTS
    The SKILL.md must never load raw .jsonl bulk into the main conversation.
    This script does the heavy lifting offline and produces a compact, machine-
    readable index. Subagents reason over the JSON, not the transcripts.

  USAGE
    .\Extract-SessionIndex.ps1                       # last 21 days, default out path
    .\Extract-SessionIndex.ps1 -Days 7               # narrower window
    .\Extract-SessionIndex.ps1 -OutputFile c:\foo.json
    .\Extract-SessionIndex.ps1 -MinSizeKb 0          # include tiny sessions too
    .\Extract-SessionIndex.ps1 -IncludeFullText      # include full first/last prompt
                                                       text (default truncates to 600 chars)

  OUTPUT SCHEMA (see references/jsonl-format.md for full doc)
    {
      "generated": "<ISO timestamp>",
      "windowDays": 21,
      "projectsRoot": "<path>",
      "sessionCount": <n>,
      "sessions": [ { ... per-session record ... } ],
      "duplicateGroups": [ { "key": "...", "sessions": [<id>, ...] } ]
    }

  CREATED
    2026-05-30. Part of session-curator v1. See plan §B.2/§B.5/§C.9/§C.10.
================================================================================
#>

[CmdletBinding()]
param(
    [int]    $Days             = 21,
    [int]    $MinSizeKb        = 2,
    [string] $ProjectsRoot     = (Join-Path $HOME '.claude' 'projects'),
    [string] $OutputFile       = (Join-Path $HOME '.claude' 'skills' 'session-curator' '.session-index.json'),
    [switch] $IncludeFullText
)

$ErrorActionPreference = 'Stop'

# --- helpers ----------------------------------------------------------------

function Truncate {
    param([string]$Text, [int]$Max = 600)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\r\n', "`n").Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max - 1) + '…'
}

function Extract-AssistantText {
    param($Content)
    if ($null -eq $Content) { return $null }
    if ($Content -is [string]) { return $Content }
    $chunks = @()
    foreach ($block in $Content) {
        if ($block.type -eq 'text' -and $block.text) { $chunks += $block.text }
    }
    return ($chunks -join "`n").Trim()
}

function Extract-UserText {
    param($Content)
    if ($null -eq $Content) { return $null }
    if ($Content -is [string]) { return $Content }
    $chunks = @()
    foreach ($block in $Content) {
        if ($block.type -eq 'text' -and $block.text) { $chunks += $block.text }
        elseif ($block -is [string]) { $chunks += $block }
    }
    return ($chunks -join "`n").Trim()
}

function Normalize-PromptForDupKey {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.ToLowerInvariant()
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
    return $t
}

function Parse-Session {
    param([System.IO.FileInfo]$File)

    $sessionId      = $File.BaseName
    $firstUser      = $null
    $lastUser       = $null
    $lastAssistant  = $null
    $userTimestamps = New-Object 'System.Collections.Generic.List[datetime]'
    $allTimestamps  = New-Object 'System.Collections.Generic.List[datetime]'
    $userCount      = 0
    $assistantCount = 0
    $cwd            = $null
    $gitBranch      = $null
    $customTitle    = $null
    $parentSessionId = $null
    $endedWithExit  = $false
    $lastLineType   = $null

    foreach ($line in [System.IO.File]::ReadLines($File.FullName)) {
        if (-not $line.StartsWith('{')) { continue }
        try { $obj = $line | ConvertFrom-Json -Depth 30 } catch { continue }

        if (-not $cwd -and $obj.cwd) { $cwd = $obj.cwd }
        if (-not $gitBranch -and $obj.gitBranch) { $gitBranch = $obj.gitBranch }

        # Custom title written by /rename — last one wins
        if ($obj.type -eq 'custom-title' -and $obj.customTitle) {
            $customTitle = $obj.customTitle
        }

        # Fork lineage — confirmed empirically 2026-05-30: `parentSessionId` is an OBJECT
        # `{sessionId, messageUuid}`, NOT a plain string. We flatten to just the sessionId.
        if (-not $parentSessionId) {
            foreach ($f in @('parentSessionId','forkedFrom','sourceSessionId','originSessionId')) {
                if ($obj.$f) {
                    $val = $obj.$f
                    $parentSessionId = if ($val -is [string]) { $val } elseif ($val.sessionId) { $val.sessionId } else { ($val | ConvertTo-Json -Compress -Depth 3) }
                    break
                }
            }
        }

        $ts = $null
        if ($obj.timestamp) {
            try { $ts = [datetime]::Parse($obj.timestamp).ToUniversalTime() } catch { $ts = $null }
            if ($ts) { $allTimestamps.Add($ts) | Out-Null }
        }

        $lastLineType = $obj.type

        if ($obj.type -eq 'user' -and $obj.message.content) {
            $text = Extract-UserText $obj.message.content
            if ($text -and $text -notmatch '^\s*<') {
                if (-not $firstUser) { $firstUser = $text }
                $lastUser = $text
                $userCount++
                if ($ts) { $userTimestamps.Add($ts) | Out-Null }
            }
        }
        elseif ($obj.type -eq 'assistant' -and $obj.message.content) {
            $text = Extract-AssistantText $obj.message.content
            if ($text) {
                $lastAssistant = $text
                $assistantCount++
            }
        }
        elseif ($obj.type -eq 'system' -and $obj.subtype -eq 'local_command' -and $obj.content -match '/exit') {
            $endedWithExit = $true
        }
    }

    # Temporal analytics — compute gaps, active minutes, days span
    $temporal = $null
    if ($allTimestamps.Count -ge 2) {
        $sorted = $allTimestamps | Sort-Object
        $first  = $sorted[0]
        $last   = $sorted[-1]
        $daysTouched = ($sorted | ForEach-Object { $_.ToLocalTime().Date } | Sort-Object -Unique).Count
        $daysSpan    = [math]::Max(1, [int]($last.Date - $first.Date).TotalDays + 1)

        # Active minutes = sum of consecutive gaps where gap < 30 min
        $activeMin = 0.0
        $gaps = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 1; $i -lt $sorted.Count; $i++) {
            $gapMin = ($sorted[$i] - $sorted[$i-1]).TotalMinutes
            if ($gapMin -lt 30) {
                $activeMin += $gapMin
            } else {
                $gaps.Add([pscustomobject]@{
                    from    = $sorted[$i-1].ToString('o')
                    to      = $sorted[$i].ToString('o')
                    minutes = [int]$gapMin
                }) | Out-Null
            }
        }
        $activeHr = [math]::Max(0.1, $activeMin / 60.0)
        $msgPerHr = [math]::Round(($userCount + $assistantCount) / $activeHr, 1)

        # Rhythm — terse English description
        $rhythm = if ($gaps.Count -eq 0) {
            "single sitting, $([int]$activeMin) min active"
        } elseif ($daysSpan -eq 1) {
            "$($gaps.Count) breaks within 1 day, $([int]$activeMin) min total"
        } else {
            "active $daysTouched of $daysSpan days, $($gaps.Count) idle gaps, $([int]$activeMin) min total active"
        }

        $temporal = [pscustomobject]@{
            firstTs       = $first.ToString('o')
            lastTs        = $last.ToString('o')
            activeMinutes = [int]$activeMin
            daysSpan      = $daysSpan
            daysActive    = $daysTouched
            intensity     = $msgPerHr
            gapCount      = $gaps.Count
            longestGapMin = if ($gaps.Count -gt 0) { [int]($gaps | Measure-Object -Property minutes -Maximum).Maximum } else { 0 }
            rhythm        = $rhythm
        }
    }

    $truncLen = if ($IncludeFullText) { 100000 } else { 600 }

    return [pscustomobject]@{
        id              = $sessionId
        file            = $File.FullName
        mtime           = $File.LastWriteTimeUtc.ToString('o')
        sizeKb          = [math]::Round($File.Length / 1024, 1)
        cwd             = $cwd
        gitBranch       = $gitBranch
        customTitle     = $customTitle
        parentSessionId = $parentSessionId
        userCount       = $userCount
        assistantCount  = $assistantCount
        endedWithExit   = $endedWithExit
        lastLineType    = $lastLineType
        firstUser       = (Truncate $firstUser $truncLen)
        lastUser        = (Truncate $lastUser $truncLen)
        lastAssistant   = (Truncate $lastAssistant $truncLen)
        temporal        = $temporal
    }
}

# --- main -------------------------------------------------------------------

if (-not (Test-Path $ProjectsRoot)) {
    throw "Projects root not found: $ProjectsRoot"
}

$outputDir = Split-Path $OutputFile
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$cutoff = (Get-Date).AddDays(-$Days).ToUniversalTime()

Write-Host "Scanning $ProjectsRoot (last $Days days, min ${MinSizeKb}KB)..." -ForegroundColor Cyan
# Exclude subagent / task transcripts at ANY depth in the path — not just when the
# IMMEDIATE parent dir is named subagents/tasks. Dynamic-workflow agents live at
# <session>/subagents/workflows/wf_<id>/agent-<hash>.jsonl, so their immediate parent
# is wf_<id> and the old `$_.Directory.Name -notmatch '^(subagents|tasks)$'` check let
# them through (319 such files inflated the index on 2026-06-10). Matching the full
# path for a \subagents\ or \tasks\ segment drops every workflow/Agent-tool subagent
# transcript while KEEPING the orchestrator ("main") session, which sits at the top
# level of the project folder, not under subagents/.
# Also exclude the .remember/ memory-system background jobs. Those are headless
# `claude -p` runs (the daily-memory summarizer + the compression pass) launched with
# cwd under the temp dir, so their transcripts land in the encoded project folder
# C--Users-<user>-AppData-Local-Temp (Windows). They are 1-turn machine jobs, never
# resumable user sessions, and there were dozens of them in a single week (2026-06-10) —
# by far the largest source of survey noise. Match the encoded 'AppData-Local-Temp' folder marker.
$files = Get-ChildItem $ProjectsRoot -Recurse -File -Filter '*.jsonl' |
    Where-Object {
        $_.LastWriteTimeUtc -gt $cutoff -and
        ($_.Length / 1024) -ge $MinSizeKb -and
        $_.FullName -notmatch '[\\/](subagents|tasks)[\\/]' -and
        $_.FullName -notmatch 'AppData-Local-Temp'
    }

Write-Host "Found $($files.Count) session(s) in window." -ForegroundColor Cyan

$sessions = New-Object 'System.Collections.Generic.List[object]'
$i = 0
foreach ($f in $files) {
    $i++
    Write-Progress -Activity 'Parsing sessions' -Status "$i / $($files.Count): $($f.BaseName)" -PercentComplete (($i / $files.Count) * 100)
    $sessions.Add( (Parse-Session $f) ) | Out-Null
}
Write-Progress -Activity 'Parsing sessions' -Completed

# Duplicate detection — group by (cwd, normalized-first-prompt, startTs ±60s)
$dupGroups = @{}
foreach ($s in $sessions) {
    if (-not $s.firstUser -or -not $s.cwd) { continue }
    $key = "$($s.cwd)||$(Normalize-PromptForDupKey $s.firstUser)"
    if (-not $dupGroups.ContainsKey($key)) { $dupGroups[$key] = New-Object 'System.Collections.Generic.List[object]' }
    $dupGroups[$key].Add($s) | Out-Null
}
$duplicateGroups = @()
foreach ($k in $dupGroups.Keys) {
    if ($dupGroups[$k].Count -lt 2) { continue }
    # Confirm within ±60s start window
    $sorted = $dupGroups[$k] | Where-Object { $_.temporal } | Sort-Object { $_.temporal.firstTs }
    if ($sorted.Count -lt 2) { continue }
    $firstTs = [datetime]::Parse($sorted[0].temporal.firstTs)
    $within60 = $sorted | Where-Object { (([datetime]::Parse($_.temporal.firstTs)) - $firstTs).TotalSeconds -le 60 }
    if ($within60.Count -ge 2) {
        $duplicateGroups += [pscustomobject]@{
            key      = $k
            sessions = @($within60 | ForEach-Object { $_.id })
        }
    }
}

# Sort sessions by mtime desc for stable output
$sortedSessions = @($sessions | Sort-Object mtime -Descending)

$result = [pscustomobject]@{
    _meta = [pscustomobject]@{
        name        = '.session-index.json'
        description = 'Compact metadata index of all Claude Code sessions under ~/.claude/projects/* within the configured time window. Generated by the session-curator skill so its SKILL.md and subagents can reason about sessions WITHOUT loading raw .jsonl bulk into the main conversation context.'
        generator   = 'session-curator/scripts/Extract-SessionIndex.ps1'
        generated   = (Get-Date).ToUniversalTime().ToString('o')
        why         = 'The Claude Code CLI has no official non-interactive way to list/search sessions across all projects. This cache is what makes cross-project survey/search/cleanup/rename/resume modes possible without re-parsing 80+ jsonl files on every skill invocation.'
        regenerate  = 'pwsh -File "~/.claude/skills/session-curator/scripts/Extract-SessionIndex.ps1" -Days <N>'
        safeToDelete = 'Yes — will be regenerated on next skill invocation. Deleting it has no effect on actual Claude Code sessions, only on this skill''s cache.'
        schemaNotes = @(
            'sessions[].parentSessionId is flattened to a plain string id (the underlying jsonl stores it as a {sessionId,messageUuid} object).',
            'sessions[].temporal is null when the session has <2 timestamped lines.',
            'duplicateGroups identifies sessions with same cwd, same normalized-first-prompt, started within 60s of each other (often remote-control "continue" fork chains).'
        )
    }
    windowDays      = $Days
    projectsRoot    = $ProjectsRoot
    sessionCount    = $sortedSessions.Count
    sessions        = $sortedSessions
    duplicateGroups = $duplicateGroups
}

$json = $result | ConvertTo-Json -Depth 12 -Compress:$false
Set-Content -Path $OutputFile -Value $json -Encoding UTF8

Write-Host ""
Write-Host "Wrote $($sortedSessions.Count) sessions to $OutputFile" -ForegroundColor Green
if ($duplicateGroups.Count -gt 0) {
    Write-Host "Detected $($duplicateGroups.Count) duplicate group(s)." -ForegroundColor Yellow
}
$withFork = @($sortedSessions | Where-Object { $_.parentSessionId }).Count
if ($withFork -gt 0) {
    Write-Host "$withFork session(s) appear to be forks (have parentSessionId or similar field)." -ForegroundColor Cyan
}
