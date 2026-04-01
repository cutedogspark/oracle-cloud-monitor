# OCI 花費守衛 — 超過上限自動停止所有實例 (Windows PowerShell)
# 建議由 Task Scheduler 每小時執行
#
# 用法: powershell -ExecutionPolicy Bypass -File scripts\cost-guard.ps1

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

$costLimit = if ($envVars["COST_LIMIT"]) { [double]$envVars["COST_LIMIT"] } else { 1.0 }
$logDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "cost-guard.log"

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

function Get-CurrentCost {
    $now = Get-Date
    $startDate = Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $endDate = $startDate.AddMonths(1)
    $start = $startDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $end = $endDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $json = & oci usage-api usage-summary request-summarized-usages `
        --tenant-id $envVars["TENANCY_ID"] `
        --time-usage-started $start `
        --time-usage-ended $end `
        --granularity MONTHLY `
        --output json 2>&1 | Out-String

    try {
        $data = ($json | ConvertFrom-Json).data
        $total = 0.0
        foreach ($item in $data.items) {
            $total += [double]($item.'computed-amount' ?? 0)
        }
        return [math]::Round($total, 4)
    } catch {
        return 0.0
    }
}

function Stop-AllInstances {
    param([double]$CurrentCost)

    Write-Log "!! ALERT: Cost `$$CurrentCost exceeds `$$costLimit! Stopping all instances..."

    $compartment = if ($envVars["COMPARTMENT_ID"]) { $envVars["COMPARTMENT_ID"] } else { $envVars["TENANCY_ID"] }
    $json = & oci compute instance list `
        --compartment-id $compartment `
        --lifecycle-state RUNNING `
        --all `
        --output json 2>&1 | Out-String

    try {
        $instances = ($json | ConvertFrom-Json).data
        $count = $instances.Count

        if ($count -eq 0) {
            Write-Log "No running instances to stop"
            return
        }

        foreach ($inst in $instances) {
            $id = $inst.id
            $name = $inst.'display-name'
            Write-Log "Stopping: $name ($id)"
            & oci compute instance action --instance-id $id --action STOP --force 2>&1 | Out-Null
        }

        Send-Notify `
            -Title "OCI Cost Guard TRIGGERED" `
            -Body "Monthly cost: `$$CurrentCost USD (limit: `$$costLimit). All $count instances have been STOPPED!" `
            -Priority "urgent"

        Write-Log "All instances stopped"
    } catch {
        Write-Log "Failed to stop instances: $_"
    }
}

# === Main ===
$currentCost = Get-CurrentCost
Write-Log "Cost check: `$$currentCost / `$$costLimit"

if ($currentCost -ge $costLimit) {
    Stop-AllInstances -CurrentCost $currentCost
} else {
    Write-Log "Cost OK"
}
