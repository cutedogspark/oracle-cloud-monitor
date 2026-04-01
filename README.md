# Oracle Cloud Free Tier Monitor

Oracle Cloud Infrastructure (OCI) Always Free 資源自動化工具，包含：

- **搶資源** — 自動重試建立 ARM A1.Flex 免費實例（搶不到就一直試）
- **花費監控** — 定期查詢帳單，超過免費額度自動停機
- **資源報表** — 一鍵查看實例、儲存、網路、花費等使用狀況

## OCI Always Free 額度

| 資源 | 免費上限 |
|---|---|
| ARM Ampere A1.Flex | 4 OCPU / 24 GB RAM（可分多台） |
| AMD E2.1.Micro | 2 台（各 1/8 OCPU / 1 GB） |
| Boot Volume | 200 GB（所有實例合計） |
| Block Volume | 2 個 / 200 GB |
| Object Storage | 20 GB |
| 出站流量 | 10 TB/月 |

> **注意**：ARM A1 資源非常搶手，特別是大阪、東京等亞太區域。建立時常出現 `Out of host capacity`，需要持續重試。

## 帳戶類型（重要）

搶資源前，請確認你的 OCI 帳戶已升級為 **Pay As You Go (PAYG)**：

```bash
# macOS / Linux
./scripts/oci-report.sh account

# Windows PowerShell
powershell -File scripts\oci-report.ps1 account
```

|  | Free Trial（免費試用） | Pay As You Go（隨用隨付） |
|---|---|---|
| 免費額度 | $300 USD / 30 天 | Always Free 資源永久免費 |
| ARM A1 搶到後 | 試用到期後**可能被回收** | **永久保留** |
| 超出免費額度 | 不收費（到期停用） | 超出部分按量收費 |
| 需要信用卡 | 不需要 | 需要（不主動扣款） |

> **強烈建議**：升級為 PAYG 再搶資源，否則搶到的 ARM A1 在試用期結束後會被回收。
> 升級方式：OCI Console → Billing → **Upgrade to Paid**
>
> 升級後只要不超出 Always Free 額度，**不會產生任何費用**。腳本內建帳戶類型檢查，非 PAYG 時會提示。

## 支援平台

| 平台 | 架構 | 腳本格式 |
|---|---|---|
| macOS | ARM (M1/M2/M3) / Intel | `.sh` (Bash) |
| Linux | AMD64 / ARM64 | `.sh` (Bash) |
| Windows 11 | AMD64 | `.ps1` (PowerShell) |

## 前置需求

- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) 已安裝並設定好 API Key
- Python 3
- curl
- 一個 [ntfy.sh](https://ntfy.sh) topic（免費推播通知）

### 一鍵安裝所有工具

**macOS / Linux：**

```bash
./scripts/install-tools.sh
```

**Windows PowerShell：**

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-tools.ps1
```

腳本會自動偵測平台並安裝 OCI CLI、Python 3，同時檢查設定是否正確。

### 手動安裝 OCI CLI

```bash
# macOS / Linux
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Windows（PowerShell 或 pip）
pip install oci-cli
```

### 設定 API Key

```bash
oci setup config
```

依照提示輸入 Tenancy OCID、User OCID、Region 等。產生的 key 需到 OCI Console → Profile → API Keys 上傳公鑰。

## 快速開始

### 1. 複製設定檔

```bash
# macOS / Linux
cp env.example .env

# Windows PowerShell
copy env.example .env
```

編輯 `.env`，填入你的 OCI 資訊：

```bash
# macOS / Linux
vim .env

# Windows
notepad .env
```

**必填欄位：**

| 欄位 | 說明 | 取得方式 |
|---|---|---|
| `TENANCY_ID` | Tenancy OCID | OCI Console → Profile → Tenancy |
| `COMPARTMENT_ID` | Compartment OCID | 通常跟 Tenancy 相同 |
| `REGION` | 區域代碼 | 如 `ap-osaka-1`、`ap-tokyo-1` |
| `AVAILABILITY_DOMAIN` | 可用性網域 | `oci iam availability-domain list` |
| `SUBNET_ID` | 子網路 OCID | `oci network subnet list --compartment-id <ID>` |
| `IMAGE_ID` | 映像檔 OCID | `./scripts/oci-report.sh images` |
| `SSH_KEY_FILE` | SSH 公鑰路徑 | 預設 `~/.ssh/id_rsa.pub` |
| `NTFY_TOPIC` | ntfy.sh 通知 topic | 自訂，如 `my-oci-notify` |

### 2. 查看資源報表

確認設定正確，先跑報表看看：

```bash
# macOS / Linux
./scripts/oci-report.sh

# Windows PowerShell
powershell -File scripts\oci-report.ps1
```

可單獨查看特定項目：

```bash
# macOS / Linux
./scripts/oci-report.sh instances   # 實例
./scripts/oci-report.sh cost        # 花費
./scripts/oci-report.sh volumes     # 儲存
./scripts/oci-report.sh network     # 網路
./scripts/oci-report.sh images      # 可用映像檔（建立實例時需要 IMAGE_ID）
./scripts/oci-report.sh limits      # 免費額度上限

# Windows PowerShell
powershell -File scripts\oci-report.ps1 instances
```

### 3. 搶 ARM A1 免費實例

```bash
# macOS / Linux
./scripts/grab-free-a1.sh

# Windows PowerShell
powershell -ExecutionPolicy Bypass -File scripts\grab-free-a1.ps1
```

腳本會每 30 秒重試一次，直到建立成功。搶到後會透過 ntfy.sh 推播通知。

> **提示**：macOS / Linux 建議用 `nohup` 或 `tmux` 在背景執行，可能需要數小時甚至數天：
>
> ```bash
> nohup ./scripts/grab-free-a1.sh &
> ```
>
> Windows 建議開一個獨立的 PowerShell 視窗執行，或使用 Task Scheduler。

### 4. 設定花費監控

#### 方法一：一鍵安裝到遠端主機（推薦）

搶到實例後，用 setup-cron 把監控部署到遠端：

```bash
./scripts/setup-cron.sh opc@<your-instance-ip>
```

這會自動：
1. 在遠端安裝 OCI CLI
2. 複製設定檔和腳本
3. 設定 cron 排程（每小時檢查花費、每天 3 次通知）

#### 方法二：手動設定 cron

SSH 到你的 OCI 實例，加入排程：

```bash
crontab -e
```

```cron
# OCI 花費通知（每天 3 次，依你的時區調整時間）
0 0,8,16 * * * /path/to/scripts/check-cost.sh >> /path/to/logs/check-cost.log 2>&1

# OCI 花費守衛（每小時，超過 $1 自動停機）
0 * * * * /path/to/scripts/cost-guard.sh >> /path/to/logs/cost-guard.log 2>&1
```

### 5. 手動測試

```bash
# macOS / Linux
./scripts/check-cost.sh     # 花費通知（會發送 ntfy 推播）
./scripts/cost-guard.sh     # 花費守衛

# Windows PowerShell
powershell -File scripts\check-cost.ps1
powershell -File scripts\cost-guard.ps1
```

## 通知設定

所有腳本透過共用的 `notify.sh` / `notify.ps1` 發送通知。**ONS email 為預設**，ntfy.sh 為選填，兩者可同時啟用。

### Email 通知（預設，透過 OCI ONS）

1. OCI Console → Application Integration → Notifications
2. Create Topic → 記下 Topic OCID
3. 在 Topic 底下 Create Subscription → 選 Email → 輸入你的信箱 → 收信確認
4. 把 Topic OCID 填入 `.env` 的 `ONS_TOPIC_ID`

> OCI ONS 免費額度：每月 100 萬則，足夠日常監控使用。

### ntfy.sh 推播通知（選填）

如果也想收手機推播：

1. 手機安裝 [ntfy app](https://ntfy.sh)（iOS / Android）
2. 在 `.env` 設定 `NTFY_TOPIC="your-topic-name"`
3. 在 app 中訂閱同名 topic
4. 不需要註冊帳號

> `NTFY_TOPIC` 留空則不發送 ntfy 通知。

## 監控機制說明

### check-cost.sh — 花費通知

- 查詢 OCI Usage API 取得當月累計花費
- 列出所有 RUNNING 狀態的實例
- 花費 $0 → 低優先通知（Free Tier 正常）
- 花費 > $0 → 高優先通知（可能超出免費額度）

### cost-guard.sh — 花費守衛

- 查詢當月花費是否超過 `COST_LIMIT`（預設 $1 USD）
- **超過時自動停止所有實例**，防止持續計費
- 發送緊急通知

### ssh-login-notify.sh — SSH 登入通知

- 透過 PAM 在 SSH 登入時自動觸發
- 發送 ntfy 通知，包含登入使用者、來源 IP、時間
- 由 `setup-cron.sh` 自動安裝，或手動安裝：

```bash
sudo cp scripts/ssh-login-notify.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/ssh-login-notify.sh
echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd
```

相關 `.env` 設定：

| 變數 | 說明 | 預設值 |
|---|---|---|
| `SSH_NOTIFY_ENABLED` | 啟用 SSH 登入通知 | `true` |
| `SSH_NOTIFY_PRIORITY` | 通知優先級 | `high` |

## 專案結構

```
oracle_cloud_monitor/
├── README.md
├── env.example          # 設定檔範本
├── .env                 # 你的設定（不會進 git）
├── .gitignore
├── scripts/
│   ├── install-tools.sh  # 工具安裝（Mac/Linux）
│   ├── install-tools.ps1 # 工具安裝（Windows PowerShell）
│   ├── grab-free-a1.sh   # 搶 ARM A1（Mac/Linux）
│   ├── grab-free-a1.ps1  # 搶 ARM A1（Windows）
│   ├── check-cost.sh     # 花費通知（Mac/Linux）
│   ├── check-cost.ps1    # 花費通知（Windows）
│   ├── cost-guard.sh     # 花費守衛（Mac/Linux）
│   ├── cost-guard.ps1    # 花費守衛（Windows）
│   ├── oci-report.sh     # 資源報表（Mac/Linux）
│   ├── oci-report.ps1        # 資源報表（Windows）
│   ├── notify.sh             # 共用通知函式（Bash）
│   ├── notify.ps1            # 共用通知函式（PowerShell）
│   ├── ssh-login-notify.sh   # SSH 登入通知（PAM）
│   └── setup-cron.sh         # 一鍵部署監控到遠端
└── logs/                # 日誌（不會進 git）
```

## 常見問題

### Q: 搶資源一直出現 Out of host capacity？

ARM A1 免費資源非常搶手，特別是亞太區域。建議：
- 選擇較冷門的 region（如 `us-phoenix-1`、`ap-melbourne-1`）
- 在離峰時段執行（凌晨 2-6 點）
- 保持腳本持續運行，通常數小時到數天內可搶到

### Q: 搶到第二台 A1 會超額嗎？

會！ARM A1 免費額度是 **4 OCPU / 24 GB 合計**，不是每台。如果你已經有一台 4/24 的 A1，再搶一台就會收費。請先確認現有資源：

```bash
./scripts/oci-report.sh instances
```

### Q: 花費守衛停機後怎麼恢復？

1. 先到 OCI Console 確認是什麼產生了費用
2. 移除超額資源
3. 手動啟動需要的實例：
```bash
oci compute instance action --instance-id <INSTANCE_OCID> --action START
```

### Q: 可以在本機 Mac 跑監控嗎？

可以，但**不建議**。Mac 不一定 24 小時開機，可能漏掉檢查。建議部署到 OCI 實例上（用 `setup-cron.sh`），讓它 7×24 監控。

## License

MIT
