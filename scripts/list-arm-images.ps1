# 列出指定 Region 所有可用的 ARM (Aarch64) 平台 Image (Windows PowerShell)
#
# 用法:
#   powershell -File scripts\list-arm-images.ps1              # 列出所有 OS
#   powershell -File scripts\list-arm-images.ps1 ubuntu        # 篩選 Ubuntu
#   powershell -File scripts\list-arm-images.ps1 oracle         # 篩選 Oracle Linux

param([string]$Filter = "")

$env:SUPPRESS_LABEL_WARNING = "True"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$envFile = Join-Path $projectDir ".env"

if (-not (Test-Path $envFile)) {
    Write-Host "!! 找不到 .env" -ForegroundColor Red
    exit 1
}

# 載入 .env
$envVars = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        if ($line -match '^(\w+)="?(.+?)"?$') {
            $envVars[$Matches[1]] = $Matches[2] -replace '\$HOME', $env:USERPROFILE -replace '~', $env:USERPROFILE
        }
    }
}

$shape = "VM.Standard.A1.Flex"

Write-Host "Region: $($envVars['REGION'])"
Write-Host "Shape:  $shape"
if ($Filter) { Write-Host "篩選:  $Filter" }
Write-Host ""

# 取得所有相容的 image
$query = 'data[*].{"display-name":"display-name", id:id, os:"operating-system", ver:"operating-system-version"}'

$resultJson = & oci compute image list `
    --compartment-id $envVars["COMPARTMENT_ID"] `
    --shape $shape `
    --sort-by TIMECREATED `
    --all `
    --output json `
    --query $query 2>&1 | Out-String

try {
    $images = $resultJson | ConvertFrom-Json
} catch {
    Write-Host "!! 查無 image" -ForegroundColor Red
    exit 1
}

if (-not $images -or $images.Count -eq 0) {
    Write-Host "!! 查無 image" -ForegroundColor Red
    exit 1
}

# 篩選
if ($Filter) {
    $filterLower = $Filter.ToLower()
    $images = $images | Where-Object {
        $_.os.ToLower().Contains($filterLower) -or $_.'display-name'.ToLower().Contains($filterLower)
    }
}

if (-not $images -or $images.Count -eq 0) {
    Write-Host "查無符合條件的 image"
    exit 0
}

# 依 OS 分組
$groups = @{}
foreach ($img in $images) {
    $key = $img.os
    if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
    $groups[$key] += $img
}

foreach ($osName in ($groups.Keys | Sort-Object)) {
    $imgs = $groups[$osName]
    Write-Host "-- $osName ($($imgs.Count)) --" -ForegroundColor Cyan
    foreach ($img in $imgs) {
        Write-Host ("  {0,10}  {1}" -f $img.ver, $img.'display-name')
        Write-Host ("             {0}" -f $img.id)
    }
    Write-Host ""
}
