<#
================================================================================
  Format-SurveyMarkdown.ps1
================================================================================

  WHAT THIS IS
    Renders the canonical markdown survey for the session-curator skill. Reads
    the compact JSON index produced by Extract-SessionIndex.ps1 and, optionally,
    a per-session verdicts NDJSON file written by subagents during survey-mode
    fan-out. Emits a single markdown document with a YAML frontmatter (so the
    artifact self-describes its provenance), an at-a-glance header, the per-project
    breakdown, the top-N table sorted by recency, and an "open threads worth
    picking up" section.

  WHY IT EXISTS
    Smoke test v1 surfaced bug J.2: the LLM in the test session improvised a
    fragile inline PowerShell one-liner to render the final survey markdown and
    hit a parser error ("Missing ')' in method call"). The output landed
    anyway but only by luck. Centralising rendering here means SKILL.md
    invokes a known-good helper and the LLM never has to roll its own
    formatter — the spec lives in one place and is testable in isolation.

  INPUTS
    -IndexFile    <path>   Path to .session-index.json from Extract-SessionIndex.ps1.
                           Defaults to ~/.claude/skills/session-curator/.session-index.json
    -VerdictsFile <path>   Optional NDJSON file, one line per session, each:
                              {"id":"<uuid>","topic":"...","status":"...","where_stopped":"..."}
                           When present, the table's Topic/Status/WhereStopped columns
                           use these subagent verdicts instead of raw heuristics.
    -Window       <int>    Time window in days for the header. Defaults to the
                           windowDays field from the index file.
    -OutputFile   <path>   Where to write. Default = stdout. Pass
                           ~/.claude/skills/session-curator/.last-survey.md to
                           persist the canonical "last survey" file.
    -TopN         <int>    How many sessions to list in the main table.
                           Defaults to 30. The rest are summarized in the footer.

  OUTPUT SHAPE
    See the bottom of this script. YAML frontmatter, then headline summary,
    per-project breakdown, a scannable top-N table (NO resume column), a
    "Resume commands" section with one standalone fenced code block per session
    (copy-pasteable; never inside a table cell — see SKILL.md > Output conventions),
    and an "open threads" tail whose resume commands are likewise standalone blocks.

  CREATED
    2026-05-31. Part of session-curator v1, bug fix from smoke test v1 (§J.2).
================================================================================
#>

[CmdletBinding()]
param(
    [string] $IndexFile    = (Join-Path $HOME '.claude' 'skills' 'session-curator' '.session-index.json'),
    [string] $VerdictsFile = $null,
    [int]    $Window       = 0,
    [string] $OutputFile   = $null,
    [int]    $TopN         = 30
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $IndexFile)) {
    throw "Index file not found: $IndexFile. Run Extract-SessionIndex.ps1 first."
}

$index = Get-Content $IndexFile -Raw | ConvertFrom-Json
if ($Window -le 0) { $Window = $index.windowDays }

# Load verdicts map (id -> {topic, status, where_stopped}) if provided
$verdicts = @{}
if ($VerdictsFile -and (Test-Path $VerdictsFile)) {
    foreach ($line in Get-Content $VerdictsFile) {
        $t = $line.Trim()
        if (-not $t.StartsWith('{')) { continue }
        try {
            $v = $t | ConvertFrom-Json
            if ($v.id) { $verdicts[$v.id] = $v }
        } catch { continue }
    }
}

# Friendly project name from cwd (collapse the home dir to ~, keep last 3 segments)
function Get-FriendlyProject {
    param([string]$Cwd)
    if (-not $Cwd) { return '<unknown>' }
    $p = $Cwd -replace '\\', '/'
    # Collapse the user's home directory to ~ — derived from $HOME so it works on
    # any user/OS, instead of hardcoding a username. (Match case-insensitively.)
    $homeNorm = ($HOME -replace '\\', '/').TrimEnd('/')
    if ($homeNorm -and $p -like "$homeNorm/*") {
        $p = '~/' + $p.Substring($homeNorm.Length + 1)
    }
    $parts = $p.TrimEnd('/').Split('/')
    if ($parts.Count -gt 4) { $p = '.../' + ($parts[-3..-1] -join '/') }
    return $p
}

function Format-Age {
    # Accept any input type — ConvertFrom-Json in pwsh 7+ auto-converts ISO dates to [datetime],
    # which would break a [string]-typed parameter via culture-specific re-stringification.
    param($IsoUtc)
    if (-not $IsoUtc) { return '' }
    try {
        $when = if ($IsoUtc -is [datetime]) {
            $IsoUtc.ToLocalTime()
        } else {
            [datetime]::Parse([string]$IsoUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
        }
        $delta = (Get-Date) - $when
        if ($delta.TotalMinutes -lt 1)  { return 'just now' }
        if ($delta.TotalMinutes -lt 60) { return "$([int]$delta.TotalMinutes)m ago" }
        if ($delta.TotalHours -lt 24)   { return "$([int]$delta.TotalHours)h ago" }
        if ($delta.TotalDays -lt 14)    { return "$([int]$delta.TotalDays)d ago" }
        return "$([int]($delta.TotalDays / 7))w ago"
    } catch { return '' }
}

function Truncate {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\r\n', ' ' -replace '\n', ' ' -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max - 1) + '…'
}

function Escape-Pipe {
    param([string]$Text)
    return ($Text -replace '\|', '\|' -replace '`', "'")
}

function Build-Resume {
    # Canonical copy-pasteable resume command: cd to the session's cwd (double-quoted,
    # since paths often contain spaces) then resume by full UUID. Falls back to a bare
    # resume when cwd is unknown. Mirrors the convention in SKILL.md > Output conventions.
    param([string]$Cwd, [string]$Id)
    if ($Cwd) { return "cd ""$Cwd""; claude --resume $Id" }
    return "claude --resume $Id"
}

$sessions = $index.sessions | Sort-Object mtime -Descending
$total    = $sessions.Count

# Per-project breakdown
$byProject = $sessions | Group-Object { Get-FriendlyProject $_.cwd } |
    Sort-Object Count -Descending | Select-Object Name, Count

# Status histogram
$statusCounts = @{}
foreach ($s in $sessions) {
    $st = if ($verdicts[$s.id]) { $verdicts[$s.id].status } else { 'unclassified' }
    if (-not $statusCounts.ContainsKey($st)) { $statusCounts[$st] = 0 }
    $statusCounts[$st]++
}

# Build the markdown
$sb = New-Object System.Text.StringBuilder

# Frontmatter
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('title: Cross-project Claude session survey')
[void]$sb.AppendLine("generator: session-curator/scripts/Format-SurveyMarkdown.ps1")
[void]$sb.AppendLine("generated: $((Get-Date).ToUniversalTime().ToString('o'))")
[void]$sb.AppendLine("window_days: $Window")
[void]$sb.AppendLine("session_count: $total")
[void]$sb.AppendLine("source_index: $IndexFile")
if ($VerdictsFile) { [void]$sb.AppendLine("verdicts_file: $VerdictsFile") }
[void]$sb.AppendLine('safe_to_delete: Yes — regenerated on next survey.')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

# Headline
[void]$sb.AppendLine("# Survey of $total session(s) across $($byProject.Count) project(s), last $Window days")
[void]$sb.AppendLine('')

# Status summary line
$statusLine = ($statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '
[void]$sb.AppendLine("**Status mix:** $statusLine")
[void]$sb.AppendLine('')

# Per-project breakdown
[void]$sb.AppendLine('## Per-project breakdown')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| Project | Sessions |')
[void]$sb.AppendLine('|---------|----------|')
foreach ($p in $byProject) {
    [void]$sb.AppendLine("| $(Escape-Pipe $p.Name) | $($p.Count) |")
}
[void]$sb.AppendLine('')

# Top-N recent — scannable table only (NO resume column; resume commands follow
# as standalone code blocks so they copy-paste cleanly — see SKILL.md > Output conventions)
$topSessions = @($sessions | Select-Object -First $TopN)
[void]$sb.AppendLine("## Top $([Math]::Min($TopN, $total)) by recency")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| # | When | Project | Topic | Status |')
[void]$sb.AppendLine('|---|------|---------|-------|--------|')
$count = 0
foreach ($s in $topSessions) {
    $count++
    $age     = Format-Age $s.mtime
    $project = Get-FriendlyProject $s.cwd
    $v       = $verdicts[$s.id]
    if ($v) {
        $topic   = Truncate $v.topic 50
        $status  = Truncate $v.status 15
    } else {
        $topic   = if ($s.customTitle) { $s.customTitle } else { Truncate $s.firstUser 50 }
        $status  = if ($s.endedWithExit) { 'closed-/exit' } else { 'unclassified' }
    }
    [void]$sb.AppendLine("| $count | $age | $(Escape-Pipe $project) | $(Escape-Pipe $topic) | $(Escape-Pipe $status) |")
}
[void]$sb.AppendLine('')
if ($total -gt $TopN) {
    [void]$sb.AppendLine("_$($total - $TopN) more session(s) in this window — re-run survey with `-TopN $total` to see all._")
    [void]$sb.AppendLine('')
}

# Resume commands — one standalone fenced code block per session (copy-pasteable;
# never inside a table cell). Numbering matches the table above.
[void]$sb.AppendLine('## Resume commands')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('_One command per block, single line — copy the whole block. The `cd` lands you in the right folder from any cwd._')
[void]$sb.AppendLine('')
$count = 0
foreach ($s in $topSessions) {
    $count++
    $age     = Format-Age $s.mtime
    $project = Get-FriendlyProject $s.cwd
    $v       = $verdicts[$s.id]
    $topic   = if ($v) { Truncate $v.topic 60 } elseif ($s.customTitle) { $s.customTitle } else { Truncate $s.firstUser 60 }
    [void]$sb.AppendLine("**$count. $(Escape-Pipe $project) — $(Escape-Pipe $topic)** _($age)_")
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine((Build-Resume $s.cwd $s.id))
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('')
}

# Open threads worth picking up — verdict==in-progress / open, mtime > 1d ago
[void]$sb.AppendLine('## Open threads you might want to pick up')
[void]$sb.AppendLine('')
$openCutoff = (Get-Date).AddDays(-1).ToUniversalTime()
$openSessions = $sessions | Where-Object {
    $v = $verdicts[$_.id]
    $isOpen = if ($v) { @('in-progress','open','abandoned') -contains $v.status } else { -not $_.endedWithExit }
    $mtimeDt = if ($_.mtime -is [datetime]) { $_.mtime } else { try { [datetime]::Parse([string]$_.mtime, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $null } }
    $isOld  = $mtimeDt -and ($mtimeDt -lt $openCutoff)
    $isOpen -and $isOld
} | Select-Object -First 10
if ($openSessions.Count -eq 0) {
    [void]$sb.AppendLine('_None — everything in this window either ended cleanly or is too recent to be "stalled"._')
} else {
    foreach ($s in $openSessions) {
        $age     = Format-Age $s.mtime
        $project = Get-FriendlyProject $s.cwd
        $v       = $verdicts[$s.id]
        $topic   = if ($v) { $v.topic } elseif ($s.customTitle) { $s.customTitle } else { Truncate $s.firstUser 50 }
        $where   = if ($v -and $v.where_stopped) { $v.where_stopped } else { Truncate $s.lastUser 80 }
        [void]$sb.AppendLine("**$(Escape-Pipe $project)** ($age) — $(Escape-Pipe $topic)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Stopped at: $(Escape-Pipe $where)")
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine((Build-Resume $s.cwd $s.id))
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine('')
    }
}
[void]$sb.AppendLine('')

# Footer
[void]$sb.AppendLine('---')
[void]$sb.AppendLine("_Index source: ``$IndexFile`` (generated $($index._meta.generated))._")
if ($index.duplicateGroups -and $index.duplicateGroups.Count -gt 0) {
    [void]$sb.AppendLine("_$($index.duplicateGroups.Count) duplicate group(s) detected — say 'clean up my sessions' to review._")
}

$output = $sb.ToString()

if ($OutputFile) {
    $outDir = Split-Path $OutputFile
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Set-Content -Path $OutputFile -Value $output -Encoding UTF8
    Write-Host "Wrote survey to $OutputFile" -ForegroundColor Green
} else {
    $output
}
