$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$result = & (Join-Path $root 'tools\Export-Project.ps1') `
    -OutputPath (Join-Path $root 'out\cut9-filters.mp4') `
    -ProjectPath (Join-Path $root 'out\cut9-filters.vpj') `
    -ExpectedDurationMs 20000
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'cut9-export.out')
