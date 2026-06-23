<#
================================================================================
  Watch-Session.ps1
================================================================================

  WHAT THIS IS
    Live tail of a Claude Code session's .jsonl transcript, with a human-readable
    formatter. Designed to run in a SECOND terminal so the user can watch what
    a session in their FIRST terminal is doing in real time — including user
    prompts, assistant replies, tool calls, and tool results — with sub-500ms
    latency.

  WHY NOT JUST `Get-Content -Wait`
    - Polls every ~1s; this script uses FileSystemWatcher (event-driven, <100ms)
    - Cannot follow `--resume`, which writes to a NEW .jsonl in the same project
      dir; this script watches the PARENT directory and switches to the new
      session file automatically
    - Doesn't handle Windows file-locking gracefully; this script opens the
      file with FileShare.ReadWrite so it never blocks the running Claude
      process

  USAGE
    .\Watch-Session.ps1 -SessionId 07092173-...
    .\Watch-Session.ps1 -File "$HOME/.claude/projects/<encoded-project>/07092173-....jsonl"
    .\Watch-Session.ps1 -SessionId 07092173 -ShowThinking   # also show <think> blocks (off by default)
    .\Watch-Session.ps1 -SessionId 07092173 -Raw            # print raw jsonl lines, no formatter

  FORMAT
    Each event is printed as a single block with a [TAG] prefix:
      [USER]      user prompt (truncated to 400 chars by default)
      [ASST]      assistant text reply
      [TOOL <n>]  tool_use call (tool name + truncated input)
      [RESULT]    tool_result (truncated)
      [THINK]     assistant thinking block (only with -ShowThinking)
      [SYS]       system events (slash commands, mode changes)

  STOP
    Ctrl+C to exit. The script unregisters its FileSystemWatcher events on
    exit via the finally block.

  CREATED
    2026-05-30. Part of session-curator v1. See plan §C.11/§E.7/§G.2.
================================================================================
#>

[CmdletBinding(DefaultParameterSetName='ById')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='ById')]
    [string] $SessionId,
    [Parameter(Mandatory=$true, ParameterSetName='ByFile')]
    [string] $File,
    [int]    $MaxLen        = 400,
    [switch] $ShowThinking,
    [switch] $Raw,
    [string] $ProjectsRoot  = (Join-Path $HOME '.claude\projects')
)

$ErrorActionPreference = 'Stop'

# --- Resolve target file ----------------------------------------------------

function Resolve-SessionFile {
    param([string]$Id, [string]$Root)
    $matches = Get-ChildItem $Root -Recurse -File -Filter "$Id*.jsonl" |
               Where-Object { $_.Directory.Name -notmatch '^(subagents|tasks)$' }
    if ($matches.Count -eq 0) { throw "No session file found for id prefix '$Id' under $Root" }
    if ($matches.Count -gt 1) {
        Write-Warning "Multiple matches; using newest:"
        $matches | Sort-Object LastWriteTime -Descending | ForEach-Object { Write-Warning "  $($_.FullName)" }
    }
    return ($matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

$targetFile = if ($PSCmdlet.ParameterSetName -eq 'ById') {
    Resolve-SessionFile -Id $SessionId -Root $ProjectsRoot
} else {
    if (-not (Test-Path $File)) { throw "File not found: $File" }
    (Resolve-Path $File).Path
}

$projectDir = Split-Path $targetFile
$resolvedId = [System.IO.Path]::GetFileNameWithoutExtension($targetFile)
Write-Host "Watching: $targetFile" -ForegroundColor Cyan
Write-Host "Project dir: $projectDir" -ForegroundColor DarkGray
Write-Host "(Ctrl+C to stop. New .jsonl files in this dir will be picked up automatically.)" -ForegroundColor DarkGray
Write-Host ""

# --- Pretty-printer ---------------------------------------------------------

function Truncate-Inline {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\r\n', "`n").Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max - 1) + '…'
}

function Format-Line {
    param([string]$Line)
    if ($Raw) { Write-Host $Line; return }
    if (-not $Line.StartsWith('{')) { return }

    try { $obj = $Line | ConvertFrom-Json -Depth 30 } catch { return }

    $ts = if ($obj.timestamp) {
        try { ([datetime]::Parse($obj.timestamp)).ToLocalTime().ToString('HH:mm:ss') } catch { '       ' }
    } else { '       ' }

    switch ($obj.type) {
        'user' {
            if (-not $obj.message.content) { return }
            $c = $obj.message.content
            if ($c -is [string]) {
                if ($c -match '^\s*<') { return }  # skip synthetic tool-result wrappers
                Write-Host "$ts [USER] " -NoNewline -ForegroundColor Green
                Write-Host (Truncate-Inline $c $MaxLen)
            } else {
                foreach ($block in $c) {
                    if ($block.type -eq 'text' -and $block.text) {
                        Write-Host "$ts [USER] " -NoNewline -ForegroundColor Green
                        Write-Host (Truncate-Inline $block.text $MaxLen)
                    } elseif ($block.type -eq 'tool_result') {
                        $resTxt = if ($block.content -is [string]) { $block.content } else { ($block.content | ConvertTo-Json -Compress -Depth 5) }
                        Write-Host "$ts [RESULT] " -NoNewline -ForegroundColor DarkGreen
                        Write-Host (Truncate-Inline $resTxt $MaxLen)
                    }
                }
            }
        }
        'assistant' {
            if (-not $obj.message.content) { return }
            foreach ($block in $obj.message.content) {
                if ($block.type -eq 'text' -and $block.text) {
                    Write-Host "$ts [ASST] " -NoNewline -ForegroundColor Cyan
                    Write-Host (Truncate-Inline $block.text $MaxLen)
                } elseif ($block.type -eq 'tool_use') {
                    $inputTxt = $block.input | ConvertTo-Json -Compress -Depth 5
                    Write-Host "$ts [TOOL $($block.name)] " -NoNewline -ForegroundColor Yellow
                    Write-Host (Truncate-Inline $inputTxt $MaxLen)
                } elseif ($block.type -eq 'thinking' -and $ShowThinking) {
                    Write-Host "$ts [THINK] " -NoNewline -ForegroundColor DarkMagenta
                    Write-Host (Truncate-Inline $block.thinking $MaxLen)
                }
            }
        }
        'system' {
            if ($obj.subtype -eq 'local_command' -and $obj.content) {
                Write-Host "$ts [SYS] " -NoNewline -ForegroundColor DarkGray
                Write-Host (Truncate-Inline $obj.content $MaxLen)
            }
        }
    }
}

# --- FileStream + position tracker ------------------------------------------

# One open stream per session file we're currently watching. Map: full path -> @{stream;reader;leftover}
$script:Streams = @{}

function Open-Stream {
    param(
        [string]$Path,
        # Startup discovery (file existed when watcher launched) → seek to end, label "tracking".
        # Runtime discovery (file appeared via FSW Created event, e.g. after /clear rotation) →
        # seek to start, label "NEW SESSION", surface the freshly-written content.
        [switch]$RuntimeDiscovery
    )
    if ($script:Streams.ContainsKey($Path)) { return }
    if (-not (Test-Path $Path)) { return }
    try {
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
        if ($RuntimeDiscovery) {
            # Brand-new file — read from beginning so /clear-rotation activity is visible
            $fs.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        } else {
            # File was already there at startup — only show NEW activity
            $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        }
        $script:Streams[$Path] = @{
            stream   = $fs
            reader   = $sr
            leftover = ''
        }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        if ($RuntimeDiscovery) {
            Write-Host "*** NEW SESSION (likely /clear-rotation): $name ***" -ForegroundColor Yellow
        } else {
            Write-Host "--- tracking (already open): $name ---" -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "Could not open $Path : $_"
    }
}

function Drain-Stream {
    param([string]$Path)
    if (-not $script:Streams.ContainsKey($Path)) { return }
    $entry = $script:Streams[$Path]
    try {
        $chunk = $entry.reader.ReadToEnd()
        if (-not $chunk) { return }
        $buffer = $entry.leftover + $chunk
        $parts = $buffer -split "`n"
        # Last part may be incomplete — keep it as leftover
        $entry.leftover = $parts[-1]
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $line = $parts[$i].TrimEnd("`r")
            if ($line) { Format-Line $line }
        }
    } catch {
        Write-Warning "Read failed on $Path : $_"
    }
}

# Initial: open the target file, drain anything already past the tail (none, since we seek to end)
Open-Stream $targetFile

# --- FileSystemWatcher ------------------------------------------------------

$watcher = [System.IO.FileSystemWatcher]::new($projectDir, '*.jsonl')
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor `
                        [System.IO.NotifyFilters]::Size -bor `
                        [System.IO.NotifyFilters]::FileName
$watcher.EnableRaisingEvents = $true

# Use simple polling loop with FSW signaling — keeps the script single-threaded and Ctrl+C-friendly
$changedQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$createdQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

$changedAction = { $event.SourceEventArgs.FullPath | ForEach-Object { $changedQueue.Enqueue($_) } }
$createdAction = { $event.SourceEventArgs.FullPath | ForEach-Object { $createdQueue.Enqueue($_) } }

$changedReg = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $changedAction -MessageData $changedQueue
$createdReg = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $createdAction -MessageData $createdQueue

try {
    while ($true) {
        # Drain change queue (de-dup by path within this tick)
        $changed = @{}
        $path = $null
        while ($changedQueue.TryDequeue([ref]$path)) { $changed[$path] = $true }
        foreach ($p in $changed.Keys) {
            if ($script:Streams.ContainsKey($p)) { Drain-Stream $p }
            elseif ($p -like "$projectDir\*.jsonl") {
                # First time we've seen this file — treat as runtime discovery
                # (e.g. a Changed event arrived before the Created event)
                Open-Stream $p -RuntimeDiscovery
                Drain-Stream $p
            }
        }
        # Drain create queue
        $created = $null
        while ($createdQueue.TryDequeue([ref]$created)) {
            if ($created -like "$projectDir\*.jsonl" -and -not $script:Streams.ContainsKey($created)) {
                Open-Stream $created -RuntimeDiscovery
                Drain-Stream $created
            }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    Unregister-Event -SourceIdentifier $changedReg.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $createdReg.Name -ErrorAction SilentlyContinue
    $watcher.Dispose()
    foreach ($entry in $script:Streams.Values) {
        $entry.reader.Dispose()
        $entry.stream.Dispose()
    }
    Write-Host "`nWatcher stopped." -ForegroundColor DarkGray
}
