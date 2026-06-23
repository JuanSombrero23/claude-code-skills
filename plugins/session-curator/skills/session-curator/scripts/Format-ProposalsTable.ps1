<#
================================================================================
  Format-ProposalsTable.ps1
================================================================================

  WHAT THIS IS
    Renders the canonical markdown review table for the session-curator skill's
    rename mode. Reads (a) the candidates JSON produced by the index slicer,
    and (b) the proposals JSON produced by the naming subagent, joins them on
    `id`, and emits a single markdown table with: When | Project | Customer |
    Proposed name | Confidence | Mismatch | Reason.

  WHY IT EXISTS
    Smoke test v2 (2026-06-01) caught the LLM in the test session improvising
    inline `node -e` shell scripts to build this table — twice. First attempt
    hit a bash substitution bug (`${p.newTitle}` interpreted by bash). Second
    attempt worked but only via a `<<'EOF'` heredoc workaround. Centralising
    rendering here removes the LLM-improvising-shell surface entirely.

  INPUTS
    -CandidatesFile <path>   Required. JSON array of candidate objects with
                             {id, file, cwd, mtime, userCount, sizeKb,
                              lastLineType, firstUser, lastUser, lastAssistant}.
                             Typically $env:TEMP\session-curator-rename-candidates.json.
    -ProposalsFile  <path>   Required. JSON array of proposal objects with
                             {id, file, newTitle, reasoning, cwdMismatch,
                              confidence}. Typically
                             $env:TEMP\session-curator-rename-proposals.json.
                             Accepts either a bare array or {proposals: [...]}
                             wrapper.
    -OutputFile     <path>   Optional. If supplied, writes the markdown to
                             this path AND prints a confirmation. If omitted,
                             prints the markdown to stdout.
    -SortBy         <key>    'recency' (default, newest first) or 'customer'
                             (groups by inferred customer prefix from newTitle).

  OUTPUT
    Markdown document with YAML frontmatter (provenance), at-a-glance summary
    line, breakdown by customer prefix, then the main proposals table. Resume
    commands are NOT included — this is a review artifact, not a resume one.

  CREATED
    2026-06-01. Smoke test v2 polish item. See plan §K.5.
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $CandidatesFile,
    [Parameter(Mandatory=$true)] [string] $ProposalsFile,
    [string] $OutputFile,
    [ValidateSet('recency','customer')] [string] $SortBy = 'recency'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CandidatesFile)) { throw "Candidates file not found: $CandidatesFile" }
if (-not (Test-Path $ProposalsFile))  { throw "Proposals file not found: $ProposalsFile" }

$candidates = Get-Content $CandidatesFile -Raw | ConvertFrom-Json
$proposalsRaw = Get-Content $ProposalsFile -Raw | ConvertFrom-Json
$proposals = if ($proposalsRaw -is [System.Collections.IList]) { $proposalsRaw } else { $proposalsRaw.proposals }
if (-not $proposals) { throw "Proposals file is empty or malformed" }

$candById = @{}
foreach ($c in $candidates) { $candById[$c.id] = $c }

function Get-CustomerPrefix {
    param([string]$Slug)
    if (-not $Slug) { return '(none)' }
    return ($Slug -split '-')[0]
}

function Format-When {
    param($Mtime)
    if (-not $Mtime) { return '(no mtime)' }
    $dt = if ($Mtime -is [datetime]) { $Mtime } else { [datetime]::Parse($Mtime, [System.Globalization.CultureInfo]::InvariantCulture) }
    return $dt.ToLocalTime().ToString('yyyy-MM-dd')
}

function Get-ProjectFolder {
    param([string]$CandFile)
    if (-not $CandFile) { return '?' }
    $parts = $CandFile -split '\\'
    $idx = [Array]::IndexOf($parts, 'projects')
    if ($idx -ge 0 -and $idx -lt $parts.Count - 1) { return $parts[$idx + 1] }
    return '?'
}

$rows = @()
foreach ($p in $proposals) {
    $c = $candById[$p.id]
    $rows += [pscustomobject]@{
        Id          = $p.id
        When        = Format-When ($c.mtime)
        WhenSort    = if ($c.mtime) { if ($c.mtime -is [datetime]) { $c.mtime } else { [datetime]::Parse($c.mtime, [System.Globalization.CultureInfo]::InvariantCulture) } } else { [datetime]::MinValue }
        Project     = Get-ProjectFolder $p.file
        Customer    = Get-CustomerPrefix $p.newTitle
        NewTitle    = $p.newTitle
        Confidence  = $p.confidence
        Mismatch    = if ($p.cwdMismatch) { 'Y' } else { '' }
        Reasoning   = ($p.reasoning -replace '\r?\n', ' ').Substring(0, [Math]::Min(($p.reasoning -replace '\r?\n', ' ').Length, 120))
    }
}

$rowsSorted = switch ($SortBy) {
    'customer' { $rows | Sort-Object Customer, WhenSort -Descending:$false }
    default    { $rows | Sort-Object WhenSort -Descending }
}

$byCustomer = $rows | Group-Object Customer | Sort-Object Count -Descending
$breakdown  = ($byCustomer | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("---")
[void]$out.AppendLine("title: Rename proposals — session-curator review table")
[void]$out.AppendLine("generator: scripts/Format-ProposalsTable.ps1")
[void]$out.AppendLine("generated: $(([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ'))")
[void]$out.AppendLine("candidatesFile: $CandidatesFile")
[void]$out.AppendLine("proposalsFile: $ProposalsFile")
[void]$out.AppendLine("count: $($rows.Count)")
[void]$out.AppendLine("sortBy: $SortBy")
[void]$out.AppendLine("safeToDelete: Yes — regenerated on next rename run.")
[void]$out.AppendLine("---")
[void]$out.AppendLine("")
[void]$out.AppendLine("**$($rows.Count) proposals.** Breakdown: $breakdown.")
[void]$out.AppendLine("")
[void]$out.AppendLine("| # | When | Project | Proposed name | Conf | Mismatch | Reason |")
[void]$out.AppendLine("|---|---|---|---|---|---|---|")
$i = 0
foreach ($r in $rowsSorted) {
    $i++
    [void]$out.AppendLine("| $i | $($r.When) | $($r.Project) | ``$($r.NewTitle)`` | $($r.Confidence) | $($r.Mismatch) | $($r.Reasoning) |")
}

$markdown = $out.ToString()
if ($OutputFile) {
    $markdown | Set-Content -LiteralPath $OutputFile -Encoding UTF8
    Write-Host "Wrote $($rows.Count) proposals to $OutputFile" -ForegroundColor Green
} else {
    Write-Output $markdown
}
