$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$result = & (Join-Path $root 'tools\Export-Project.ps1') `
    -OutputPath (Join-Path $PSScriptRoot 'audio-ladder.mp4') `
    -ProjectPath (Join-Path $PSScriptRoot 'audio-ladder.vpj') `
    -ExpectedDurationMs 12000
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'audio-ladder.out')
