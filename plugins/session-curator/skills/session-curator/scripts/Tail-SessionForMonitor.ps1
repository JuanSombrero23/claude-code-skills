param(
    [Parameter(Mandatory)][string]$File
)

# Emits one stdout line per meaningful session event for the Monitor tool.
# Quiet on tool_use noise; loud on user prompts, assistant text, errors.

$ErrorActionPreference = 'Continue'

function Emit($tag, $body) {
    if (-not $body) { return }
    $body = ($body -replace '\s+', ' ').Trim()
    if ($body.Length -gt 240) { $body = $body.Substring(0, 240) + '...' }
    Write-Output "[$tag] $body"
}

# -Wait keeps the cmdlet alive; -Tail 0 starts at end of file (skip backlog)
Get-Content -Path $File -Wait -Tail 0 | ForEach-Object {
    $line = $_
    if (-not $line) { return }

    try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { return }

    switch ($o.type) {
        'user' {
            $c = $o.message.content
            if ($c -is [string]) {
                Emit 'USER' $c
            } elseif ($c -is [array]) {
                $txt = ($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' '
                if ($txt) { Emit 'USER' $txt }
                # tool_result blocks intentionally suppressed (noise)
            }
        }
        'assistant' {
            $txt = ($o.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' '
            $tools = ($o.message.content | Where-Object { $_.type -eq 'tool_use' } | ForEach-Object { "$($_.name)" }) -join ', '
            if ($txt) { Emit 'ASST' $txt }
            if ($tools) { Emit 'TOOL' $tools }
        }
        'system' {
            if ($o.content -match 'error|denied|blocked|fail') { Emit 'SYS' $o.content }
        }
    }
} | ForEach-Object { $_; [Console]::Out.Flush() }
