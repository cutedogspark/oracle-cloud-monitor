# OCI 花費通知 — 查詢當月花費並發送通知 (Windows PowerShell)
# 建議由 Task Scheduler 定期執行
#
# 用法: powershell -ExecutionPolicy Bypass -File scripts\check-cost.ps1

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

# 載入共用通知函式
. "$scriptDir\notify.ps1"

$logDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "check-cost.log"

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

# === 查詢本月花費 ===
$now = Get-Date
$startDate = Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0
$endDate = $startDate.AddMonths(1)
$start = $startDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$end = $endDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$costJson = & oci usage-api usage-summary request-summarized-usages `
    --tenant-id $envVars["TENANCY_ID"] `
    --time-usage-started $start `
    --time-usage-ended $end `
    --granularity MONTHLY `
    --output json 2>&1 | Out-String

if (-not $costJson -or $costJson -match "Error") {
    Write-Log "ERROR: Failed to query OCI usage API"
    Send-Notify -Title "OCI Cost Check Failed" -Body "Failed to query OCI usage API at $(Get-Date)" -Priority "high"
    exit 1
}

# 解析花費
$costData = $costJson | ConvertFrom-Json
$items = $costData.data.items
$total = 0.0
$services = @{}

foreach ($item in $items) {
    $amt = [double]($item.'computed-amount' ?? 0)
    $total += $amt
    $svc = $item.service ?? "Unknown"
    if ($amt -ne 0) {
        if ($services.ContainsKey($svc)) { $services[$svc] += $amt } else { $services[$svc] = $amt }
    }
}

$totalStr = "{0:F4}" -f $total

# === 查詢運行中的實例 ===
$compartment = if ($envVars["COMPARTMENT_ID"]) { $envVars["COMPARTMENT_ID"] } else { $envVars["TENANCY_ID"] }
$instancesJson = & oci compute instance list `
    --compartment-id $compartment `
    --lifecycle-state RUNNING `
    --all `
    --output json 2>&1 | Out-String

$instanceList = ""
try {
    $instances = ($instancesJson | ConvertFrom-Json).data
    foreach ($inst in $instances) {
        $instanceList += "  $($inst.'display-name') ($($inst.shape))`n"
    }
} catch {
    $instanceList = "  (query failed)`n"
}

# === 組合訊息 ===
$month = Get-Date -Format "yyyy-MM"
$nowStr = Get-Date -Format "yyyy-MM-dd HH:mm"

$message = @"
OCI ${month} Monthly Cost: `$$totalStr USD
Time: ${nowStr}

Running Instances:
${instanceList}
"@

if ($total -ne 0) {
    $detail = ""
    foreach ($svc in ($services.GetEnumerator() | Sort-Object -Property Value -Descending)) {
        $detail += "  $($svc.Key): `$$('{0:F4}' -f $svc.Value)`n"
    }
    $message += "`nCost Breakdown:`n$detail"
}

if ($total -eq 0) {
    $priority = "low"
    $title = "OCI Daily Report: `$0 (Free)"
} else {
    $priority = "high"
    $title = "OCI Daily Report: `$$totalStr USD"
}

Write-Log $message

# === 發送通知 ===
Send-Notify -Title $title -Body $message -Priority $priority

Write-Log "Done"
