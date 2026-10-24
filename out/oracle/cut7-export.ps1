$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$r = & (Join-Path $root "tools\Export-Project.ps1") -OutputPath (Join-Path $root "out\cut7-audio.mp4") -ProjectPath (Join-Path $root "out\cut7-audio.vpj") -ExpectedDurationMs 12000
$r | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot "cut7-export.out")
