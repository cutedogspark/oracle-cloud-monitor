# Oracle Cloud Monitor — Windows PowerShell 工具安裝腳本
# 支援: Windows 11 (PowerShell 5.1+)
#
# 用法: powershell -ExecutionPolicy Bypass -File scripts\install-tools.ps1

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Oracle Cloud Monitor — Windows 工具安裝檢查" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# === 偵測平台 ===
Write-Host "[>] 偵測平台" -ForegroundColor Yellow
$arch = if ([Environment]::Is64BitOperatingSystem) { "AMD64" } else { "x86" }
$osVer = [System.Environment]::OSVersion.Version
Write-Host "  平台: Windows $($osVer.Major).$($osVer.Minor) ($arch)"
Write-Host ""

# === 檢查 Python ===
Write-Host "[>] 檢查 Python3" -ForegroundColor Yellow
$pythonCmd = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) {
    $pythonCmd = "python3"
    $pyVer = & python3 --version 2>&1
    Write-Host "  OK Python3 已安裝: $pyVer" -ForegroundColor Green
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $pyVer = & python --version 2>&1
    if ($pyVer -match "Python 3") {
        $pythonCmd = "python"
        Write-Host "  OK Python 已安裝: $pyVer" -ForegroundColor Green
    } else {
        Write-Host "  !! 找到 Python 但不是 3.x: $pyVer" -ForegroundColor Red
    }
}

if (-not $pythonCmd) {
    Write-Host "  安裝 Python3..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  使用 winget 安裝..."
        winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements
        Write-Host "  OK Python3 安裝完成，請重新開啟終端後再執行此腳本" -ForegroundColor Green
    } else {
        Write-Host "  !! 請手動安裝 Python3:" -ForegroundColor Red
        Write-Host "     https://www.python.org/downloads/" -ForegroundColor Red
        Write-Host "     安裝時務必勾選 'Add Python to PATH'" -ForegroundColor Red
    }
}
Write-Host ""

# === 檢查 OCI CLI ===
Write-Host "[>] 檢查 OCI CLI" -ForegroundColor Yellow
$ociCmd = $null
if (Get-Command oci -ErrorAction SilentlyContinue) {
    $ociCmd = "oci"
    $ociVer = & oci --version 2>&1
    Write-Host "  OK OCI CLI 已安裝: $ociVer" -ForegroundColor Green
} else {
    # 檢查預設安裝路徑
    $ociDefault = "$env:LOCALAPPDATA\Programs\Oracle\oci-cli\oci.exe"
    if (Test-Path $ociDefault) {
        $ociCmd = $ociDefault
        Write-Host "  OK OCI CLI 已安裝在: $ociDefault" -ForegroundColor Green
        Write-Host "  !! 請加入 PATH: $env:LOCALAPPDATA\Programs\Oracle\oci-cli\" -ForegroundColor Yellow
    } else {
        Write-Host "  安裝 OCI CLI..." -ForegroundColor Yellow
        if ($pythonCmd) {
            Write-Host "  使用 pip 安裝..."
            & $pythonCmd -m pip install oci-cli
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK OCI CLI 安裝完成" -ForegroundColor Green
            } else {
                Write-Host "  !! pip 安裝失敗，嘗試官方安裝程式..." -ForegroundColor Yellow
                $installerUrl = "https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1"
                $installerPath = "$env:TEMP\oci-install.ps1"
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
                & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath
            }
        } else {
            Write-Host "  !! 請先安裝 Python3 再安裝 OCI CLI" -ForegroundColor Red
        }
    }
}
Write-Host ""

# === 檢查 OCI 設定 ===
Write-Host "[>] 檢查 OCI 設定" -ForegroundColor Yellow
$ociConfig = "$env:USERPROFILE\.oci\config"
if (Test-Path $ociConfig) {
    Write-Host "  OK OCI config 已存在: $ociConfig" -ForegroundColor Green

    # 驗證連線
    if ($ociCmd) {
        Write-Host "  驗證 OCI 連線..."
        $env:SUPPRESS_LABEL_WARNING = "True"
        try {
            $result = & $ociCmd iam region list --query "data[0].name" --output json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK OCI API 連線正常" -ForegroundColor Green
            } else {
                Write-Host "  !! OCI API 連線失敗，請檢查 config 和 API key" -ForegroundColor Red
                Write-Host "     重新設定: oci setup config" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  !! OCI API 連線失敗: $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  !! OCI config 不存在" -ForegroundColor Yellow
    Write-Host "     請執行: oci setup config" -ForegroundColor Yellow
    Write-Host "     需要 Tenancy OCID、User OCID、Region 等資訊" -ForegroundColor Yellow
}
Write-Host ""

# === 檢查 .env ===
Write-Host "[>] 檢查 .env 設定檔" -ForegroundColor Yellow
$projectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$envFile = Join-Path $projectDir ".env"
$envExample = Join-Path $projectDir "env.example"

if (Test-Path $envFile) {
    Write-Host "  OK .env 已存在" -ForegroundColor Green
    $content = Get-Content $envFile -Raw
    if ($content -match "xxxxxxxxxxxxxxxxxxxx") {
        Write-Host "  !! .env 含有範例值，請編輯填入真實的 OCID" -ForegroundColor Yellow
        Write-Host "     notepad $envFile" -ForegroundColor Yellow
    }
} elseif (Test-Path $envExample) {
    Copy-Item $envExample $envFile
    Write-Host "  OK 已建立 .env（從 env.example 複製）" -ForegroundColor Green
    Write-Host "  !! 請編輯 .env 填入你的 OCI 設定:" -ForegroundColor Yellow
    Write-Host "     notepad $envFile" -ForegroundColor Yellow
} else {
    Write-Host "  !! 找不到 env.example" -ForegroundColor Red
}
Write-Host ""

# === 檢查帳戶類型 ===
Write-Host "[>] 檢查帳戶類型" -ForegroundColor Yellow
if ((Test-Path $envFile) -and $ociCmd) {
    # 從 .env 讀取 TENANCY_ID
    $tenancyId = $null
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^TENANCY_ID="?(.+?)"?$') { $tenancyId = $Matches[1] }
    }

    if ($tenancyId) {
        try {
            $subJson = & $ociCmd organizations subscription list `
                --compartment-id $tenancyId --output json 2>&1 | Out-String
            $subData = ($subJson | ConvertFrom-Json).data.items
            $activeSub = $subData | Where-Object { $_.'lifecycle-state' -eq 'ACTIVE' } | Select-Object -First 1
            $pm = if ($activeSub) { $activeSub.'payment-model' } else { "UNKNOWN" }

            if ($pm -eq "PAYG") {
                Write-Host "  OK 帳戶類型: Pay As You Go (PAYG)" -ForegroundColor Green
            } else {
                Write-Host "  !! 帳戶類型: $pm (非 PAYG)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "     Free Trial 與 Pay As You Go 的差異：" -ForegroundColor Yellow
                Write-Host "     Free Trial:    30 天 `$300 額度，到期後資源可能被回收"
                Write-Host "     Pay As You Go: Always Free 永久免費，超額才收費"
                Write-Host ""
                Write-Host "     建議升級為 PAYG: OCI Console -> Billing -> Upgrade to Paid" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  !! 無法查詢帳戶類型" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  !! .env 缺少 TENANCY_ID" -ForegroundColor Yellow
    }
} else {
    Write-Host "  -- 跳過（OCI CLI 未安裝或 .env 不存在）" -ForegroundColor Gray
}
Write-Host ""

# === 檢查 SSH Key ===
Write-Host "[>] 檢查 SSH Key" -ForegroundColor Yellow
$sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa.pub"

# 從 .env 讀取自訂路徑
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile
    foreach ($line in $envContent) {
        if ($line -match '^SSH_KEY_FILE="(.+)"') {
            $sshKeyPath = $Matches[1] -replace '\$HOME', $env:USERPROFILE -replace '~', $env:USERPROFILE
        }
    }
}

if (Test-Path $sshKeyPath) {
    Write-Host "  OK SSH 公鑰存在: $sshKeyPath" -ForegroundColor Green
} else {
    Write-Host "  !! SSH 公鑰不存在: $sshKeyPath" -ForegroundColor Yellow
    Write-Host "     產生新的: ssh-keygen -t rsa -b 4096" -ForegroundColor Yellow
}
Write-Host ""

# === 完成 ===
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  安裝檢查完成！" -ForegroundColor Cyan
Write-Host ""
Write-Host "  下一步："
Write-Host "    1. 確認 .env 設定正確"
Write-Host "    2. 查看資源報表: powershell -File scripts\oci-report.ps1"
Write-Host "    3. 搶 ARM A1:    powershell -File scripts\grab-free-a1.ps1"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
