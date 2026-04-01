# OCI 資源報表 — 查詢帳戶下的資源使用狀況 (Windows PowerShell)
#
# 用法:
#   powershell -File scripts\oci-report.ps1              # 完整報表
#   powershell -File scripts\oci-report.ps1 instances     # 只看實例
#   powershell -File scripts\oci-report.ps1 cost          # 只看花費
#   powershell -File scripts\oci-report.ps1 volumes       # 只看儲存
#   powershell -File scripts\oci-report.ps1 network       # 只看網路
#   powershell -File scripts\oci-report.ps1 images        # 列出可用映像檔
#   powershell -File scripts\oci-report.ps1 limits        # 查看免費額度上限

param([string]$Section = "all")

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

$compartment = if ($envVars["COMPARTMENT_ID"]) { $envVars["COMPARTMENT_ID"] } else { $envVars["TENANCY_ID"] }

function Write-Separator {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 42) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 42) -ForegroundColor Cyan
}

# === 實例 ===
function Show-Instances {
    Write-Separator "Compute Instances"

    Write-Host ""
    Write-Host "  Running:" -ForegroundColor Yellow
    & oci compute instance list `
        --compartment-id $compartment `
        --lifecycle-state RUNNING `
        --all `
        --query 'data[].{"Name":"display-name","Shape":shape,"OCPU":"shape-config"."ocpus","RAM(GB)":"shape-config"."memory-in-gbs","Created":"time-created"}' `
        --output table 2>&1

    Write-Host ""
    Write-Host "  Stopped:" -ForegroundColor Yellow
    & oci compute instance list `
        --compartment-id $compartment `
        --lifecycle-state STOPPED `
        --all `
        --query 'data[].{"Name":"display-name","Shape":shape,"OCPU":"shape-config"."ocpus","RAM(GB)":"shape-config"."memory-in-gbs"}' `
        --output table 2>&1

    # 免費額度統計
    Write-Host ""
    Write-Host "  ARM A1 Free Tier Usage:" -ForegroundColor Yellow
    $json = & oci compute instance list `
        --compartment-id $compartment `
        --lifecycle-state RUNNING `
        --all `
        --output json 2>&1 | Out-String

    try {
        $instances = ($json | ConvertFrom-Json).data
        $a1Ocpus = 0; $a1Memory = 0; $microCount = 0
        foreach ($inst in $instances) {
            if ($inst.shape -match "A1") {
                $a1Ocpus += $inst.'shape-config'.ocpus
                $a1Memory += $inst.'shape-config'.'memory-in-gbs'
            } elseif ($inst.shape -match "Micro") {
                $microCount++
            }
        }
        Write-Host "    ARM A1:   $a1Ocpus/4 OCPU, $a1Memory/24 GB RAM"
        Write-Host "    E2 Micro: $microCount/2 instances"
    } catch {
        Write-Host "    (query failed)"
    }
}

# === 花費 ===
function Show-Cost {
    Write-Separator "Monthly Cost"

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
        $services = @{}
        foreach ($item in $data.items) {
            $amt = [double]($item.'computed-amount' ?? 0)
            $total += $amt
            $svc = $item.service ?? "Unknown"
            if ($amt -ne 0) {
                if ($services.ContainsKey($svc)) { $services[$svc] += $amt } else { $services[$svc] = $amt }
            }
        }

        $month = Get-Date -Format "yyyy-MM"
        Write-Host "    $month Total: `$$("{0:F4}" -f $total) USD"
        if ($total -eq 0) {
            Write-Host "    OK All within Free Tier" -ForegroundColor Green
        } else {
            Write-Host ""
            foreach ($svc in ($services.GetEnumerator() | Sort-Object -Property Value -Descending)) {
                Write-Host "      $($svc.Key): `$$("{0:F4}" -f $svc.Value)"
            }
        }
    } catch {
        Write-Host "    (query failed)"
    }
}

# === 儲存 ===
function Show-Volumes {
    Write-Separator "Storage"

    Write-Host ""
    Write-Host "  Boot Volumes:" -ForegroundColor Yellow
    & oci bv boot-volume list `
        --compartment-id $compartment `
        --availability-domain $envVars["AVAILABILITY_DOMAIN"] `
        --all `
        --query 'data[].{"Name":"display-name","Size(GB)":"size-in-gbs","State":"lifecycle-state"}' `
        --output table 2>&1

    Write-Host ""
    Write-Host "  Block Volumes:" -ForegroundColor Yellow
    & oci bv volume list `
        --compartment-id $compartment `
        --availability-domain $envVars["AVAILABILITY_DOMAIN"] `
        --all `
        --query 'data[].{"Name":"display-name","Size(GB)":"size-in-gbs","State":"lifecycle-state"}' `
        --output table 2>&1

    # 統計
    Write-Host ""
    Write-Host "  Free Tier Storage Usage:" -ForegroundColor Yellow
    $bootJson = & oci bv boot-volume list `
        --compartment-id $compartment `
        --availability-domain $envVars["AVAILABILITY_DOMAIN"] `
        --all --output json 2>&1 | Out-String
    try {
        $boots = ($bootJson | ConvertFrom-Json).data
        $bootTotal = ($boots | ForEach-Object { $_.'size-in-gbs' } | Measure-Object -Sum).Sum
        Write-Host "    Boot Volumes: $bootTotal/200 GB"
    } catch { Write-Host "    Boot Volumes: 0/200 GB" }

    $blockJson = & oci bv volume list `
        --compartment-id $compartment `
        --availability-domain $envVars["AVAILABILITY_DOMAIN"] `
        --all --output json 2>&1 | Out-String
    try {
        $blocks = ($blockJson | ConvertFrom-Json).data
        $blockTotal = ($blocks | ForEach-Object { $_.'size-in-gbs' } | Measure-Object -Sum).Sum
        $blockCount = $blocks.Count
        Write-Host "    Block Volumes: $blockCount/2 volumes, $blockTotal/200 GB"
    } catch { Write-Host "    Block Volumes: 0/2 volumes, 0/200 GB" }
}

# === 網路 ===
function Show-Network {
    Write-Separator "Network"

    Write-Host ""
    Write-Host "  VCN:" -ForegroundColor Yellow
    & oci network vcn list `
        --compartment-id $compartment `
        --all `
        --query 'data[].{"Name":"display-name","CIDR":"cidr-block","State":"lifecycle-state"}' `
        --output table 2>&1

    Write-Host ""
    Write-Host "  Subnets:" -ForegroundColor Yellow
    & oci network subnet list `
        --compartment-id $compartment `
        --all `
        --query 'data[].{"Name":"display-name","CIDR":"cidr-block","Public":"prohibit-public-ip-on-vnic"}' `
        --output table 2>&1

    Write-Host ""
    Write-Host "  Public IPs:" -ForegroundColor Yellow
    & oci network public-ip list `
        --compartment-id $compartment `
        --scope REGION `
        --all `
        --query 'data[].{"IP":"ip-address","Lifetime":"lifetime","State":"lifecycle-state"}' `
        --output table 2>&1
}

# === 映像檔 ===
function Show-Images {
    Write-Separator "Available Images (for instance launch)"

    Write-Host ""
    Write-Host "  Oracle Linux (ARM - aarch64):" -ForegroundColor Yellow
    & oci compute image list `
        --compartment-id $compartment `
        --shape "VM.Standard.A1.Flex" `
        --all `
        --query 'data[?"operating-system"==``Oracle Linux``].{"Name":"display-name","OCID":id}' `
        --output table 2>&1 | Select-Object -First 20

    Write-Host ""
    Write-Host "  Ubuntu (ARM - aarch64):" -ForegroundColor Yellow
    & oci compute image list `
        --compartment-id $compartment `
        --shape "VM.Standard.A1.Flex" `
        --all `
        --query 'data[?"operating-system"==``Canonical Ubuntu``].{"Name":"display-name","OCID":id}' `
        --output table 2>&1 | Select-Object -First 20
}

# === 免費額度 ===
function Show-Limits {
    Write-Separator "OCI Always Free Tier Limits"

    Write-Host ""
    Write-Host "  Resource                    Free Tier Limit" -ForegroundColor White
    Write-Host "  --------------------------  ---------------------"
    Write-Host "  ARM A1.Flex Compute         4 OCPU / 24 GB RAM"
    Write-Host "  E2.1.Micro Compute          2 instances"
    Write-Host "  Boot Volume Storage         200 GB total"
    Write-Host "  Block Volume Storage        2 vol / 200 GB total"
    Write-Host "  Object Storage              20 GB"
    Write-Host "  Outbound Data Transfer      10 TB/month"
    Write-Host "  Load Balancer               1 (10 Mbps)"
    Write-Host "  Monitoring                  500M ingestion"
    Write-Host "  Notifications               1M per month"
    Write-Host "  Logging                     10 GB/month"
    Write-Host ""
    Write-Host "  ARM 資源可分配在多台實例上，但總和不能超過 4 OCPU / 24 GB" -ForegroundColor Gray
    Write-Host "  Boot Volume 包含所有實例的開機磁碟，加總不能超過 200 GB" -ForegroundColor Gray
}

# === 帳戶類型 ===
function Show-Account {
    Write-Separator "Account Type"
    Write-Host ""

    try {
        $subJson = & oci organizations subscription list `
            --compartment-id $envVars["TENANCY_ID"] `
            --output json 2>&1 | Out-String
        $subData = ($subJson | ConvertFrom-Json).data.items
        $activeSub = $subData | Where-Object { $_.'lifecycle-state' -eq 'ACTIVE' } | Select-Object -First 1

        if ($activeSub) {
            $pm = $activeSub.'payment-model'
            $startDate = if ($activeSub.'start-date') { $activeSub.'start-date'.Substring(0, 10) } else { "N/A" }
            $endDate = if ($activeSub.'end-date') { $activeSub.'end-date'.Substring(0, 10) } else { "N/A" }

            if ($pm -eq "PAYG") {
                Write-Host "  OK Plan: Pay As You Go (PAYG)" -ForegroundColor Green
                Write-Host "     Always Free 資源永久免費，超出免費額度才收費"
            } elseif ($pm -eq "PROMO" -or $pm -eq "FREE") {
                Write-Host "  !! Plan: $pm (免費試用)" -ForegroundColor Yellow
                Write-Host "     開始: $startDate"
                Write-Host "     到期: $endDate"
                Write-Host ""
                Write-Host "     !! 試用期結束後，非 Always Free 資源（含搶到的 ARM A1）可能被回收！" -ForegroundColor Red
                Write-Host "     建議升級為 PAYG: OCI Console -> Billing -> Upgrade to Paid" -ForegroundColor Yellow
            } else {
                Write-Host "  Plan: $pm"
                Write-Host "     開始: $startDate"
                Write-Host "     到期: $endDate"
            }
        } else {
            Write-Host "  (無法確認帳戶類型)"
        }
    } catch {
        Write-Host "  (查詢失敗)"
    }
}

# === Main ===
Write-Host ""
Write-Host "  OCI Resource Report — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

switch ($Section) {
    "instances" { Show-Instances }
    "cost"      { Show-Cost }
    "volumes"   { Show-Volumes }
    "network"   { Show-Network }
    "images"    { Show-Images }
    "limits"    { Show-Limits }
    "account"   { Show-Account }
    "all"       {
        Show-Account
        Show-Instances
        Show-Cost
        Show-Volumes
        Show-Network
        Show-Limits
    }
    default {
        Write-Host "Usage: oci-report.ps1 [instances|cost|volumes|network|images|limits|account|all]"
        exit 1
    }
}

Write-Host ""
