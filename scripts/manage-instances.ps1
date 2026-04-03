# 互動式 OCI 實例管理 — 列出 VM 並選擇關閉 (Windows PowerShell)
#
# 用法: powershell -ExecutionPolicy Bypass -File scripts\manage-instances.ps1

$ErrorActionPreference = "Stop"
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

Write-Host "[>] 查詢 $($envVars['REGION']) 的實例..." -ForegroundColor Yellow
Write-Host ""

$instancesJson = & oci compute instance list `
    --compartment-id $envVars["COMPARTMENT_ID"] `
    --output json 2>&1 | Out-String

try {
    $allInstances = ($instancesJson | ConvertFrom-Json).data
    $instances = $allInstances | Where-Object { $_.'lifecycle-state' -ne 'TERMINATED' }
} catch {
    $instances = @()
}

if (-not $instances -or $instances.Count -eq 0) {
    Write-Host "目前沒有運行中的實例。"
    exit 0
}

# 查詢每個實例的公網 IP 並格式化顯示
Write-Host "[>] 查詢公網 IP..." -ForegroundColor Yellow

$stateMarker = @{
    'RUNNING'      = '[RUN]'
    'STOPPED'      = '[STOP]'
    'STOPPING'     = '[...]'
    'STARTING'     = '[...]'
    'PROVISIONING' = '[...]'
}

$count = $instances.Count
Write-Host ""
Write-Host ("=" * 39) -ForegroundColor Cyan
Write-Host "  找到 $count 個實例 (Region: $($envVars['REGION']))" -ForegroundColor Cyan
Write-Host ("=" * 39) -ForegroundColor Cyan
Write-Host ""

for ($i = 0; $i -lt $instances.Count; $i++) {
    $inst = $instances[$i]
    $ocid = $inst.id
    $state = $inst.'lifecycle-state'
    $marker = if ($stateMarker.ContainsKey($state)) { $stateMarker[$state] } else { '[???]' }
    $name = $inst.'display-name'
    $shape = $inst.shape
    $ocpus = $inst.'shape-config'.ocpus
    $mem = $inst.'shape-config'.'memory-in-gbs'
    $created = if ($inst.'time-created') { $inst.'time-created'.Substring(0, 10) } else { "N/A" }

    $ip = "N/A"
    try {
        $vnicsJson = & oci compute instance list-vnics `
            --instance-id $ocid --output json 2>&1 | Out-String
        $vnics = ($vnicsJson | ConvertFrom-Json).data
        if ($vnics -and $vnics.Count -gt 0 -and $vnics[0].'public-ip') {
            $ip = $vnics[0].'public-ip'
        }
    } catch { }

    $num = $i + 1
    $stateColor = switch ($state) {
        'RUNNING' { 'Green' }
        'STOPPED' { 'Red' }
        default   { 'Yellow' }
    }

    Write-Host "  $num) " -NoNewline
    Write-Host "$marker " -ForegroundColor $stateColor -NoNewline
    Write-Host $name
    Write-Host "     狀態: $state  |  IP: $ip"
    Write-Host "     規格: $shape ($ocpus OCPU / ${mem}GB)"
    Write-Host "     建立: $created"
    Write-Host "     OCID: $ocid"
    Write-Host ""
}

$choice = Read-Host "輸入要終止的編號 (多個用逗號分隔，q 取消)"

if (-not $choice -or $choice -match "^[qQ]$") {
    Write-Host "已取消。"
    exit 0
}

# 解析選擇
$selections = $choice -replace '\s', '' -split ','
$targets = @()
foreach ($s in $selections) {
    try {
        $idx = [int]$s - 1
        if ($idx -ge 0 -and $idx -lt $instances.Count) {
            $targets += $instances[$idx]
        }
    } catch { }
}

if ($targets.Count -eq 0) {
    Write-Host "!! 無效的選擇。" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "!! 即將終止以下實例：" -ForegroundColor Yellow
Write-Host ""
foreach ($t in $targets) {
    Write-Host "  - $($t.'display-name') ($($t.'lifecycle-state'))"
}

Write-Host ""
$confirm = Read-Host "確定要終止嗎？此操作無法復原 (yes/N)"

if ($confirm -ne "yes") {
    Write-Host "已取消。"
    exit 0
}

Write-Host ""
foreach ($t in $targets) {
    $name = $t.'display-name'
    $ocid = $t.id
    Write-Host "[>] 終止 $name ..."
    try {
        & oci compute instance terminate `
            --instance-id $ocid `
            --preserve-boot-volume false `
            --force 2>&1 | Out-Null
        Write-Host "  OK $name 已送出終止請求" -ForegroundColor Green
    } catch {
        Write-Host "  !! $name 終止失敗" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "完成。實例將在幾分鐘內完全終止。"
