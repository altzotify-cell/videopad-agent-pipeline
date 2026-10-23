param([string]$A, [string]$B)

function Read-Sections([string]$path) {
    $lines = Get-Content -LiteralPath $path
    $sec = @{}
    $cur = $null
    foreach ($l in $lines) {
        if ($l -match '^(\w+)=(\d+)$') { $cur = $matches[1]; $sec[$cur] = @(); continue }
        if ($cur) { $sec[$cur] += $l }
    }
    return $sec
}

function Get-F1($line, [string]$key) {
    $m = [regex]::Match($line, '(?:^|&)' + [regex]::Escape($key) + '=([^&]*)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Show-Chains([string]$path) {
    $lines = Get-Content -LiteralPath $path
    Write-Host "=== $path"
    foreach ($l in $lines) {
        if ($l -notmatch '^size=') { continue }
        $size = Get-F1 $l 'size'
        if ([int]$size -eq 0) { continue }
        Write-Host ('hclip=' + (Get-F1 $l 'hclip') + ' size=' + $size + ' mute=' + (Get-F1 $l 'mute'))
        for ($i = 0; $i -lt [int]$size; $i++) {
            $preset = [uri]::UnescapeDataString((Get-F1 $l ('preset' + $i)))
            $data = [uri]::UnescapeDataString((Get-F1 $l ('data' + $i)))
            Write-Host ('  [' + $i + '] type=' + (Get-F1 $l ('type' + $i)) + ' preset=' + $preset)
            Write-Host ('      ' + $data)
        }
    }
}

function Show-Timeline([string]$path) {
    $lines = Get-Content -LiteralPath $path
    Write-Host "=== $path (trackclips)"
    foreach ($l in $lines) {
        if ($l -notmatch '^h=\d+&') { continue }
        if (-not $l.Contains('htrack=')) { continue }
        Write-Host ('h=' + (Get-F1 $l 'h') + ' in=' + (Get-F1 $l 'in') + ' out=' + (Get-F1 $l 'out') + ' offset=' + (Get-F1 $l 'offset') + ' hlinked=' + (Get-F1 $l 'hlinked'))
    }
}

Show-Timeline $A
Show-Timeline $B
Show-Chains $A
Show-Chains $B
