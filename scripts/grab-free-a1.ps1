# Oracle Cloud Free Tier — 搶 ARM A1.Flex 資源 (Windows PowerShell)
# 自動重試建立實例，直到搶到為止
#
# 用法: powershell -ExecutionPolicy Bypass -File scripts\grab-free-a1.ps1

$ErrorActionPreference = "Stop"
$env:SUPPRESS_LABEL_WARNING = "True"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$envFile = Join-Path $projectDir ".env"

if (-not (Test-Path $envFile)) {
    Write-Host "!! 找不到 .env，請先複製 env.example 並填入設定：" -ForegroundColor Red
    Write-Host "   copy env.example .env" -ForegroundColor Red
    exit 1
}

# 載入 .env
$envVars = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        if ($line -match '^(\w+)="?(.+?)"?$') {
            $key = $Matches[1]
            $val = $Matches[2] -replace '\$HOME', $env:USERPROFILE -replace '~', $env:USERPROFILE
            $envVars[$key] = $val
        }
    }
}

# 載入共用通知函式
. "$scriptDir\notify.ps1"

# 驗證必要變數
$required = @("COMPARTMENT_ID", "AVAILABILITY_DOMAIN", "SUBNET_ID", "IMAGE_ID", "SSH_KEY_FILE", "DISPLAY_NAME", "OCPUS", "MEMORY", "BOOT_SIZE")
foreach ($var in $required) {
    if (-not $envVars.ContainsKey($var) -or [string]::IsNullOrWhiteSpace($envVars[$var])) {
        Write-Host "!! .env 缺少設定: $var" -ForegroundColor Red
        exit 1
    }
}

# === 檢查帳戶類型 (Pay As You Go) ===
Write-Host "[>] 檢查帳戶類型..." -ForegroundColor Yellow
try {
    $subJson = & oci organizations subscription list `
        --compartment-id $envVars["TENANCY_ID"] `
        --output json 2>&1 | Out-String
    $subData = ($subJson | ConvertFrom-Json).data.items
    $activeSub = $subData | Where-Object { $_.'lifecycle-state' -eq 'ACTIVE' } | Select-Object -First 1
    $paymentModel = if ($activeSub) { $activeSub.'payment-model' } else { "UNKNOWN" }
} catch {
    $paymentModel = "UNKNOWN"
}

if ($paymentModel -ne "PAYG") {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host "  !! 帳戶類型: $paymentModel (非 Pay As You Go)" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  你的帳戶目前不是 Pay As You Go (PAYG)。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Free Trial (免費試用):" -ForegroundColor Cyan
    Write-Host "    - 30 天試用期，含 `$300 USD 免費額度"
    Write-Host "    - 試用期結束後，非 Always Free 資源會被刪除"
    Write-Host "    - ARM A1 實例可能在試用結束後被回收"
    Write-Host ""
    Write-Host "  Pay As You Go (隨用隨付):" -ForegroundColor Green
    Write-Host "    - Always Free 資源永久免費"
    Write-Host "    - ARM A1 (4 OCPU / 24GB) 不會被回收"
    Write-Host "    - 超出免費額度才會收費"
    Write-Host "    - 需綁定信用卡，但不會主動扣款"
    Write-Host ""
    Write-Host "  建議：升級為 PAYG 以確保搶到的實例不會被回收。" -ForegroundColor Yellow
    Write-Host "  升級方式：OCI Console -> Billing -> Upgrade to Paid" -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "  是否仍要繼續搶資源？(y/N)"
    if ($answer -notmatch "^[yY]") {
        Write-Host "  已取消。"
        exit 0
    }
    Write-Host ""
} else {
    Write-Host "  OK 帳戶類型: Pay As You Go (PAYG)" -ForegroundColor Green
}

$shape = "VM.Standard.A1.Flex"
$retryInterval = 30
$logDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "grab-free-a1.log"

# shape-config 暫存檔
$shapeConfigFile = [System.IO.Path]::GetTempFileName()
$shapeConfig = @{ ocpus = [int]$envVars["OCPUS"]; memoryInGBs = [int]$envVars["MEMORY"] } | ConvertTo-Json
Set-Content -Path $shapeConfigFile -Value $shapeConfig

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

try {
    Write-Log "=========================================="
    Write-Log "開始搶 ARM A1.Flex ($($envVars['OCPUS']) OCPU / $($envVars['MEMORY'])GB RAM)"
    Write-Log "名稱: $($envVars['DISPLAY_NAME'])"
    Write-Log "Region: $($envVars['REGION'])"
    Write-Log "每 ${retryInterval} 秒重試一次"
    Write-Log "=========================================="

    $attempt = 0
    while ($true) {
        $attempt++
        Write-Log "--- 第 $attempt 次嘗試 ---"

        try {
            $result = & oci compute instance launch `
                --compartment-id $envVars["COMPARTMENT_ID"] `
                --availability-domain $envVars["AVAILABILITY_DOMAIN"] `
                --shape $shape `
                --shape-config "file://$shapeConfigFile" `
                --image-id $envVars["IMAGE_ID"] `
                --subnet-id $envVars["SUBNET_ID"] `
                --display-name $envVars["DISPLAY_NAME"] `
                --boot-volume-size-in-gbs $envVars["BOOT_SIZE"] `
                --assign-public-ip true `
                --ssh-authorized-keys-file $envVars["SSH_KEY_FILE"] `
                --output json 2>&1

            $resultStr = $result | Out-String

            if ($resultStr -match '"lifecycle-state"') {
                Write-Log "OK $($envVars['DISPLAY_NAME']) 建立成功！"
                Write-Log $resultStr

                # 發送通知
                Send-Notify `
                    -Title "OCI A1 搶到了！" `
                    -Body "$($envVars['DISPLAY_NAME']) ($($envVars['OCPUS']) OCPU / $($envVars['MEMORY'])GB) 建立成功！第 ${attempt} 次嘗試" `
                    -Priority "urgent"
                Write-Log "已發送通知"
                break
            }

            # 解析錯誤
            $errorMsg = ""
            $errorCode = ""
            if ($resultStr -match '"code"\s*:\s*"([^"]+)"') { $errorCode = $Matches[1] }
            if ($resultStr -match '"message"\s*:\s*"([^"]+)"') { $errorMsg = $Matches[1] }
            if (-not $errorMsg) { $errorMsg = ($result | Select-Object -Last 3) -join " " }

            if ($errorMsg -match "(?i)capacity") {
                Write-Log "!! [缺貨] $errorMsg"
                Write-Log "等待 ${retryInterval} 秒後重試..."
                Start-Sleep -Seconds $retryInterval
            } elseif ($errorCode -eq "TooManyRequests") {
                $waitTime = $retryInterval * 2
                Write-Log "!! [限流] 請求太頻繁！等待 ${waitTime} 秒..."
                Start-Sleep -Seconds $waitTime
            } elseif ($errorMsg -match "(?i)(timed|timeout|connection)") {
                Write-Log "!! [超時] 連線逾時，等待 ${retryInterval} 秒後重試..."
                Start-Sleep -Seconds $retryInterval
            } else {
                $prefix = if ($errorCode) { "${errorCode}: " } else { "" }
                Write-Log "!! 失敗: ${prefix}${errorMsg}"
                Write-Log "等待 ${retryInterval} 秒後重試..."
                Start-Sleep -Seconds $retryInterval
            }
        } catch {
            Write-Log "!! 例外: $_"
            Write-Log "等待 ${retryInterval} 秒後重試..."
            Start-Sleep -Seconds $retryInterval
        }
    }

    Write-Log "=========================================="
    Write-Log "完成！"
    Write-Log "=========================================="
} finally {
    Remove-Item -Path $shapeConfigFile -ErrorAction SilentlyContinue
}
