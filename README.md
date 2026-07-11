# Oracle Cloud Free Tier Monitor

Oracle Cloud Infrastructure (OCI) Always Free resource automation tools, including:

- **Resource Grabbing** — Automatically retries creating ARM A1.Flex free instances (keeps trying until successful)
- **Cost Monitoring** — Periodically queries billing and automatically stops instances when free tier limits are exceeded
- **Automatic Backup** — Scheduled Boot Volume backups with rotation and one-click restore
- **Resource Reporting** — One-command overview of instances, storage, network, and cost usage

## OCI Always Free Limits

| Resource | Free Limit |
|---|---|
| ARM Ampere A1.Flex | 4 OCPU / 24 GB RAM (can be split across multiple instances) |
| AMD E2.1.Micro | 2 instances (each 1/8 OCPU / 1 GB) |
| Boot Volume | 200 GB (total across all instances) |
| Block Volume | 2 volumes / 200 GB |
| Object Storage | 20 GB |
| Outbound Data Transfer | 10 TB/month |

> **Note**: ARM A1 resources are highly competitive, especially in Asia-Pacific regions like Osaka and Tokyo. Instance creation often fails with `Out of host capacity`, requiring continuous retries.

## Account Type (Important)

Before grabbing resources, ensure your OCI account has been upgraded to **Pay As You Go (PAYG)**:

```bash
# macOS / Linux
./scripts/oci-report.sh account

# Windows PowerShell
powershell -File scripts\oci-report.ps1 account
```

|  | Free Trial | Pay As You Go |
|---|---|---|
| Free Credits | $300 USD / 30 days | Always Free resources permanently free |
| After grabbing ARM A1 | **May be reclaimed** after trial expires | **Permanently retained** |
| Exceeding free limits | No charge (suspended after expiry) | Pay-as-you-go for overage |
| Credit card required | No | Yes (no automatic charges) |

> **Strongly Recommended**: Upgrade to PAYG before grabbing resources, otherwise ARM A1 instances will be reclaimed after the trial period ends.
> Upgrade path: OCI Console → Billing → **Upgrade to Paid**
>
> After upgrade, as long as you stay within Always Free limits, **no charges will be incurred**. Scripts include built-in account type checks and will prompt if not PAYG.

## Supported Platforms

| Platform | Architecture | Script Format |
|---|---|---|
| macOS | ARM (M1/M2/M3) / Intel | `.sh` (Bash) |
| Linux | AMD64 / ARM64 | `.sh` (Bash) |
| Windows 11 | AMD64 | `.ps1` (PowerShell) |

## Prerequisites

- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed and configured with API Key
- Python 3
- curl
- An [ntfy.sh](https://ntfy.sh) topic (free push notifications)

### One-Click Tool Installation

**macOS / Linux:**

```bash
./scripts/install-tools.sh
```

**Windows PowerShell:**

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-tools.ps1
```

The script automatically detects the platform and installs OCI CLI, Python 3, and verifies configuration.

### Manual OCI CLI Installation

```bash
# macOS / Linux
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Windows (PowerShell or pip)
pip install oci-cli
```

### Configure API Key

```bash
oci setup config
```

Follow prompts to enter Tenancy OCID, User OCID, Region, etc. Upload the generated public key to OCI Console → Profile → API Keys.

## Quick Start

### 1. Copy Configuration File

```bash
# macOS / Linux
cp env.example .env

# Windows PowerShell
copy env.example .env
```

Edit `.env` and fill in your OCI information:

```bash
# macOS / Linux
vim .env

# Windows
notepad .env
```

**Required Fields:**

| Field | Description | How to Obtain |
|---|---|---|
| `TENANCY_ID` | Tenancy OCID | OCI Console → Profile → Tenancy |
| `COMPARTMENT_ID` | Compartment OCID | Usually same as Tenancy |
| `REGION` | Region code | e.g., `ap-osaka-1`, `ap-tokyo-1` |
| `AVAILABILITY_DOMAIN` | Availability Domain | `oci iam availability-domain list` |
| `SUBNET_ID` | Subnet OCID | `oci network subnet list --compartment-id <ID>` |
| `IMAGE_ID` | Image OCID | `./scripts/oci-report.sh images` |
| `SSH_KEY_FILE` | SSH public key path | Default `~/.ssh/id_rsa.pub` |
| `NTFY_TOPIC` | ntfy.sh notification topic | Custom, e.g., `my-oci-notify` |

### 2. View Resource Reports

Verify configuration is correct by running reports first:

```bash
# macOS / Linux
./scripts/oci-report.sh

# Windows PowerShell
powershell -File scripts\oci-report.ps1
```

View specific items individually:

```bash
# macOS / Linux
./scripts/oci-report.sh instances   # Instances
./scripts/oci-report.sh cost        # Cost
./scripts/oci-report.sh volumes     # Storage
./scripts/oci-report.sh network     # Network
./scripts/oci-report.sh images      # Available images (needed for IMAGE_ID when creating instances)
./scripts/oci-report.sh backups     # Backup list
./scripts/oci-report.sh limits      # Free tier limits

# Windows PowerShell
powershell -File scripts\oci-report.ps1 instances
```

### 3. Grab ARM A1 Free Instance

```bash
# macOS / Linux
./scripts/grab-free-a1.sh

# Windows PowerShell
powershell -ExecutionPolicy Bypass -File scripts\grab-free-a1.ps1
```

The script retries every 30 seconds until successfully created. After grabbing, it automatically binds a **Reserved Public IP** (static IP) and sends notifications via ntfy.sh.

> Reserved IP logic: When the script starts, it automatically checks if a Reserved IP already exists in the account. If yes, it reuses it (IP remains unchanged); if no, it creates one automatically. Free Tier includes 1 free Reserved IP.

> **Tip**: For macOS / Linux, it's recommended to run in background using `nohup` or `tmux`, as it may take hours or even days:
>
> ```bash
> nohup ./scripts/grab-free-a1.sh &
> ```
>
> For Windows, open a dedicated PowerShell window or use Task Scheduler.

### 4. Query Available Images

Before grabbing resources, query all ARM images in the region to choose your OS:

```bash
./scripts/list-arm-images.sh              # List all OS
./scripts/list-arm-images.sh ubuntu        # Ubuntu only
./scripts/list-arm-images.sh oracle        # Oracle Linux only
```

After finding the target image, fill its OCID into `IMAGE_ID` in `.env`.

### 5. Manage Existing Instances

Interactive view/terminate instances:

```bash
./scripts/manage-instances.sh
```

Lists all instances (including status, public IP, specs), allowing you to select which ones to terminate.

### 6. Configure Cost Monitoring

#### Method 1: One-Click Installation to Remote Host (Recommended)

After grabbing an instance, use setup-cron to deploy monitoring remotely:

```bash
# Default user for Ubuntu image is ubuntu, for Oracle Linux is opc
./scripts/setup-cron.sh ubuntu@<your-instance-ip>
```

This automatically:
1. Installs OCI CLI on remote host
2. Copies configuration files and scripts
3. Sets up cron schedule (hourly cost check, 3 daily notifications)

#### Method 2: Manual Cron Setup

SSH into your OCI instance and add schedule:

```bash
crontab -e
```

```cron
# OCI cost notification (3 times daily, adjust time per your timezone)
0 0,8,16 * * * /path/to/scripts/check-cost.sh >> /path/to/logs/check-cost.log 2>&1

# OCI cost guard (hourly, auto-stop when exceeding $1)
0 * * * * /path/to/scripts/cost-guard.sh >> /path/to/logs/cost-guard.log 2>&1
```

### 7. Backup and Restore

#### Manual Backup

```bash
./scripts/backup-instance.sh                # Interactive mode: select instance, type, confirm
./scripts/backup-instance.sh --auto         # Auto mode: direct backup (for cron)
./scripts/backup-instance.sh <instance-id>  # Direct backup of specified instance
```

Backups use OCI Boot Volume Backup (Always Free includes 5 slots), defaulting to keeping latest 2 backups with automatic rotation of old backups.

#### Automatic Backup (Weekly)

After deployment via `setup-cron.sh`, weekly backups are automatically scheduled for Sunday 02:00. Can also be manually added to cron:

```cron
0 */3 * * * ~/oci-monitor/scripts/backup-instance.sh --auto >> ~/oci-monitor/logs/backup-instance.log 2>&1
```

#### Restore from Backup

```bash
./scripts/restore-instance.sh                # Interactive mode: lists all backups for selection
./scripts/restore-instance.sh <backup-id>    # Direct restore using specified backup OCID
```

Restore process:
1. Terminate existing instance (old Boot Volume retained as precaution)
2. Create new Boot Volume from backup
3. Launch new instance with new Boot Volume
4. Automatically rebind Reserved IP
5. After confirmation, optionally delete old Boot Volume

#### Check Backup Status

```bash
./scripts/oci-report.sh backups
```

`.env` backup-related settings:

| Variable | Description | Default |
|---|---|---|
| `BACKUP_KEEP` | Number of backups to retain | `5` |
| `BACKUP_TYPE` | Backup type (`INCREMENTAL` / `FULL`) | `INCREMENTAL` |

### 8. Manual Testing

```bash
# macOS / Linux
./scripts/check-cost.sh     # Cost notification (sends ntfy push)
./scripts/cost-guard.sh     # Cost guard

# Windows PowerShell
powershell -File scripts\check-cost.ps1
powershell -File scripts\cost-guard.ps1
```

## Notification Configuration

All scripts send notifications via shared `notify.sh` / `notify.ps1`. **ONS email is default**, ntfy.sh is optional; both can be enabled simultaneously.

### Email Notification (Default, via OCI ONS)

1. OCI Console → Application Integration → Notifications
2. Create Topic → Note Topic OCID
3. Under Topic, Create Subscription → Select Email → Enter your email → Confirm via received email
4. Fill Topic OCID into `ONS_TOPIC_ID` in `.env`

> OCI ONS free limit: 1 million messages/month, sufficient for daily monitoring.

### ntfy.sh Push Notification (Optional)

If you also want mobile push notifications:

1. Install [ntfy app](https://ntfy.sh) on phone (iOS / Android)
2. Set `NTFY_TOPIC="your-topic-name"` in `.env`
3. Subscribe to same topic in app
4. No registration required

> Leave `NTFY_TOPIC` empty to disable ntfy notifications.

## Monitoring Mechanism Details

### check-cost.sh — Cost Notification

- Queries OCI Usage API for current month cumulative cost
- Lists all instances in RUNNING state
- Cost $0 → Low priority notification (Free Tier normal)
- Cost > $0 → High priority notification (may exceed free limits)

### cost-guard.sh — Cost Guard

- Checks if current month cost exceeds `COST_LIMIT` (default $1 USD)
- **Automatically stops all instances when exceeded** to prevent continued billing
- Sends emergency notification

### ssh-login-notify.sh — SSH Login Notification

- Automatically triggered via PAM on SSH login
- Sends ntfy notification containing login user, source IP, timestamp
- Automatically installed by `setup-cron.sh`, or manual installation:

```bash
sudo cp scripts/ssh-login-notify.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/ssh-login-notify.sh
echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd
```

Related `.env` settings:

| Variable | Description | Default |
|---|---|---|
| `SSH_NOTIFY_ENABLED` | Enable SSH login notification | `true` |
| `SSH_NOTIFY_PRIORITY` | Notification priority | `high` |

## Project Structure

```
oracle_cloud_monitor/
├── README.md
├── env.example          # Configuration template
├── .env                 # Your configuration (not committed to git)
├── .gitignore
├── scripts/
│   ├── install-tools.sh  # Tool installation (Mac/Linux)
│   ├── install-tools.ps1 # Tool installation (Windows PowerShell)
│   ├── grab-free-a1.sh   # Grab ARM A1 (Mac/Linux)
│   ├── grab-free-a1.ps1  # Grab ARM A1 (Windows)
│   ├── check-cost.sh     # Cost notification (Mac/Linux)
│   ├── check-cost.ps1    # Cost notification (Windows)
│   ├── cost-guard.sh     # Cost guard (Mac/Linux)
│   ├── cost-guard.ps1    # Cost guard (Windows)
│   ├── oci-report.sh     # Resource report (Mac/Linux)
│   ├── oci-report.ps1        # Resource report (Windows)
│   ├── notify.sh             # Shared notification function (Bash)
│   ├── notify.ps1            # Shared notification function (PowerShell)
│   ├── ssh-login-notify.sh   # SSH login notification (PAM)
│   ├── backup-instance.sh    # Boot Volume auto backup + rotation
│   ├── restore-instance.sh   # Restore instance from backup
│   ├── setup-cron.sh         # One-click deploy monitoring to remote
│   ├── list-arm-images.sh    # Query available ARM images
│   └── manage-instances.sh   # Interactive instance management (view/terminate)
└── logs/                # Logs (not committed to git)
```

## FAQ

### Q: Keep getting "Out of host capacity" when grabbing resources?

ARM A1 free resources are highly competitive, especially in Asia-Pacific regions. Recommendations:
- Choose less popular regions (e.g., `us-phoenix-1`, `ap-melbourne-1`)
- Run during off-peak hours (2-6 AM local time)
- Keep script running continuously; usually succeeds within hours to days

### Q: Will grabbing a second A1 exceed limits?

Yes! ARM A1 free limit is **4 OCPU / 24 GB total**, not per instance. If you already have one 4/24 A1, grabbing another will incur charges. Check existing resources first:

```bash
./scripts/oci-report.sh instances
```

### Q: How to recover after cost guard shuts down instances?

1. First check OCI Console to identify what incurred charges
2. Remove excess resources
3. Manually start needed instances:
```bash
oci compute instance action --instance-id <INSTANCE_OCID> --action START
```

### Q: Can I run monitoring locally on Mac?

Yes, but **not recommended**. Mac may not be on 24/7, potentially missing checks. Recommended to deploy to OCI instance (using `setup-cron.sh`) for 7×24 monitoring.

## License

MIT
