# 共用通知函式 — 供其他 PowerShell 腳本載入使用
# ONS email 為預設，ntfy.sh 為選填
#
# 用法（在其他腳本中）:
#   . "$PSScriptRoot\notify.ps1"
#   Send-Notify -Title "標題" -Body "內容" -Priority "high"

function Send-Notify {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$Priority = "default"
    )

    $sent = $false

    # 1. ONS email（預設）
    if ($envVars["ONS_TOPIC_ID"]) {
        try {
            & oci ons message publish `
                --topic-id $envVars["ONS_TOPIC_ID"] `
                --title $Title `
                --body $Body 2>&1 | Out-Null
            Write-Host "[notify] ONS email sent: $Title"
            $sent = $true
        } catch {
            Write-Host "[notify] ONS email failed: $Title" -ForegroundColor Red
        }
    }

    # 2. ntfy.sh（選填）
    if ($envVars["NTFY_TOPIC"]) {
        $ntfyTags = switch ($Priority) {
            "urgent" { "rotating_light" }
            "high"   { "warning" }
            "low"    { "white_check_mark" }
            default  { "bell" }
        }

        try {
            $headers = @{
                "Title"    = $Title
                "Priority" = $Priority
                "Tags"     = $ntfyTags
            }
            Invoke-RestMethod -Uri "https://ntfy.sh/$($envVars['NTFY_TOPIC'])" `
                -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) `
                -Headers $headers | Out-Null
            Write-Host "[notify] ntfy sent: $Title"
            $sent = $true
        } catch {
            Write-Host "[notify] ntfy failed: $Title" -ForegroundColor Red
        }
    }

    if (-not $sent) {
        Write-Host "[notify] WARNING: 未設定任何通知方式（ONS_TOPIC_ID 和 NTFY_TOPIC 都是空的）" -ForegroundColor Yellow
    }
}
