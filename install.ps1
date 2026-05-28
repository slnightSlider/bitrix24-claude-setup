# Bitrix24 MCP Setup for Claude Code
# Usage: irm https://config.rsqt.com.kg/install.ps1 | iex

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$REPO_ZIP = "https://github.com/slnightSlider/bitrix24-claude-setup/archive/refs/heads/master.zip"
$INSTALL_DIR = "C:\bitrix24-mcp-server"
$CONFIG_URL = "https://config.rsqt.com.kg"

function Write-Step($n, $text) { Write-Host "`n[$n/5] $text" -ForegroundColor Cyan }
function Write-OK($text)       { Write-Host "  OK: $text" -ForegroundColor Green }
function Write-Fail($text)     { Write-Host "  ERR: $text" -ForegroundColor Red; exit 1 }

# --- Splash ----------------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host ' .S  sdSS_SSSSSSbs    sSSs    sSSs   .S    S.          .S    S.     sSSSSs  ' -ForegroundColor Green
Write-Host '.SS  YSSS~S%SSSSSP   d%%SP   d%%SP  .SS    SS.        .SS    SS.   d%%%%SP  ' -ForegroundColor Green
Write-Host 'S%S       S%S       d%S     d%S     S%S    S%S        S%S    S&S  d%S       ' -ForegroundColor Green
Write-Host 'S%S       S%S       S%S     S%S     S%S    S%S        S%S    d*S  S%S       ' -ForegroundColor Green
Write-Host 'S&S       S&S       S&S     S&S     S%S SSSS%S        S&S   .S*S  S&S       ' -ForegroundColor Green
Write-Host 'S&S       S&S       S&S_Ss  S&S     S&S  SSS&S        S&S_sdSSS   S&S       ' -ForegroundColor Green
Write-Host 'S&S       S&S       S&S~SP  S&S     S&S    S&S        S&S~YSSY%b  S&S       ' -ForegroundColor Green
Write-Host 'S&S       S&S       S&S     S&S     S&S    S&S        S&S    `S%  S&S sSSs  ' -ForegroundColor Green
Write-Host 'S*S       S*S       S*b     S*b     S*S    S*S        S*S     S%  S*b `S%%  ' -ForegroundColor Green
Write-Host 'S*S       S*S       S*S.    S*S.    S*S    S*S        S*S     S&  S*S   S%  ' -ForegroundColor Green
Write-Host 'S*S       S*S        SSSbs   SSSbs  S*S    S*S        S*S     S&   SS_sSSS  ' -ForegroundColor Green
Write-Host 'S*S       S*S         YSSP    YSSP  SSS    S*S   SS   S*S     SS    Y~YSSY  ' -ForegroundColor Green
Write-Host 'SP        SP                               SP   S%%S  SP                    ' -ForegroundColor Green
Write-Host 'Y         Y                                Y     SS   Y                     ' -ForegroundColor Green
Write-Host ""
Write-Host "  Bitrix24  x  Claude Code  //  MCP Setup" -ForegroundColor White
Write-Host "  ----------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$init = @(
    "Initializing environment",
    "Loading configuration",
    "Checking system"
)
foreach ($msg in $init) {
    Write-Host "  [ ] $msg" -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 350
    Write-Host "`r  [+] $msg" -ForegroundColor DarkGreen
}
Write-Host ""

# --- 1. Auth ---------------------------------------------------------------------
Write-Step 1 "Login (browser will open)"
Write-Host "  Sign in with your work email to get access." -ForegroundColor Cyan

$cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
$cfPath = if ($cfCmd) { $cfCmd.Source } else { $null }
if (-not $cfPath) {
    Write-Host "  Installing cloudflared..." -ForegroundColor Yellow
    winget install --id Cloudflare.cloudflared --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    $cfPath = if ($cfCmd) { $cfCmd.Source } else { $null }
    if (-not $cfPath) { Write-Fail "cloudflared install failed. Manual install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" }
}

$AUTH_URL = "$CONFIG_URL/employee.json"
cloudflared access login $AUTH_URL

$cfToken = (cloudflared access token --app $AUTH_URL).ToString().Trim()
if (-not $cfToken -or $cfToken -like "*error*") { Write-Fail "Could not get Cloudflare Access token" }

$headers = @{ "cf-access-token" = $cfToken }

$adminConfig = $null
try {
    $adminConfig = Invoke-RestMethod "$CONFIG_URL/admin.json" -Headers $headers -ErrorAction Stop
    Write-OK "Role: admin (bitrix24 + bitrix24-admin)"
} catch {}

$empConfig = $null
try {
    $empConfig = Invoke-RestMethod "$CONFIG_URL/employee.json" -Headers $headers -ErrorAction Stop
} catch {
    Write-Fail "Access denied. Ask your admin to add your email."
}
Write-OK "Access granted"

# --- 2. Dependencies -------------------------------------------------------------
Write-Step 2 "Checking dependencies"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "  Installing Node.js LTS..." -ForegroundColor Yellow
    winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { Write-Fail "Node.js install failed. Manual install: https://nodejs.org" }
}
$raw = node --version 2>&1
$ver = $raw.ToString().TrimStart('v')
$major = [int]($ver.Split('.')[0])
if ($major -lt 18) { Write-Fail "Node.js $ver is too old, need 18+. Download: https://nodejs.org" }
Write-OK "Node.js v$ver"

$pyCmd = Get-Command python -ErrorAction SilentlyContinue
$pyReal = $pyCmd -and $pyCmd.Source -notlike "*WindowsApps*"
if (-not $pyReal) {
    Write-Host "  Installing Python 3.13..." -ForegroundColor Yellow
    winget install --id Python.Python.3.13 -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    $pyReal = $pyCmd -and $pyCmd.Source -notlike "*WindowsApps*"
}
if ($pyReal) {
    $pyVer = (& python --version 2>&1).ToString().Replace("Python ","").Trim()
    Write-OK "Python $pyVer"
} else {
    Write-Host "  Python not installed, skipping (optional)" -ForegroundColor DarkGray
}

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host "  Installing Git..." -ForegroundColor Yellow
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) { Write-Fail "Git install failed. Manual install: https://git-scm.com" }
}
$gitVer = (git --version 2>&1).ToString().Replace("git version ","")
Write-OK "Git $gitVer"

# --- 3. Download and install MCP server ------------------------------------------
Write-Step 3 "Installing MCP server"
$zip = "$env:TEMP\bitrix24-mcp.zip"
Invoke-WebRequest $REPO_ZIP -OutFile $zip
$tmp = "$env:TEMP\bitrix24-mcp-extract"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip -DestinationPath $tmp
Remove-Item $zip

if (Test-Path $INSTALL_DIR) {
    Get-Process node -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*bitrix24*" -or $_.MainModule.FileName -like "*bitrix24*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $INSTALL_DIR) { Write-Fail "Cannot remove $INSTALL_DIR - close Claude Code and retry" }
}
New-Item -ItemType Directory -Force $INSTALL_DIR | Out-Null
$extracted = Get-ChildItem $tmp | Select-Object -First 1
Copy-Item "$($extracted.FullName)\build"             "$INSTALL_DIR\build"             -Recurse
Copy-Item "$($extracted.FullName)\package.json"      "$INSTALL_DIR\package.json"
Copy-Item "$($extracted.FullName)\package-lock.json" "$INSTALL_DIR\package-lock.json"
Remove-Item $tmp -Recurse -Force

Write-Host "  npm install..." -ForegroundColor Yellow
Push-Location $INSTALL_DIR
cmd /c "npm install --omit=dev --silent"
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Fail "npm install failed" }
Pop-Location
Write-OK "Installed to $INSTALL_DIR"

# --- 4. Patch .claude.json -------------------------------------------------------
Write-Step 4 "Configuring Claude Code"
$claudeFile = "$env:USERPROFILE\.claude.json"
if (-not (Test-Path $claudeFile)) { Write-Fail ".claude.json not found - is Claude Code installed?" }

$claude = Get-Content $claudeFile -Raw | ConvertFrom-Json

$mcp = [PSCustomObject]@{
    bitrix24 = [PSCustomObject]@{
        type    = "stdio"
        command = "node"
        args    = @("$INSTALL_DIR\build\index.js")
        env     = [PSCustomObject]@{ BITRIX24_WEBHOOK_URL = $empConfig.webhookUrl }
    }
}

if ($adminConfig) {
    $mcp | Add-Member -NotePropertyName "bitrix24-admin" -NotePropertyValue ([PSCustomObject]@{
        type    = "stdio"
        command = "node"
        args    = @("$INSTALL_DIR\build\index.js")
        env     = [PSCustomObject]@{ BITRIX24_WEBHOOK_URL = $adminConfig.adminWebhookUrl }
    })
}

$claude | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue $mcp -Force
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($claudeFile, ($claude | ConvertTo-Json -Depth 10), $utf8NoBom)

# --- 5. Configure permissions and org context ------------------------------------
Write-Step 5 "Configuring permissions and org context"

$settingsFile = "$env:USERPROFILE\.claude\settings.json"
if (Test-Path $settingsFile) {
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json

    $permissions = [PSCustomObject]@{
        defaultMode = "auto"
        allow       = @(
            "mcp__bitrix24__*",
            "mcp__bitrix24-admin__*",
            "Bash(*)",
            "PowerShell(*)",
            "Read(*)",
            "Write(*)",
            "Edit(*)",
            "Glob(*)",
            "Grep(*)",
            "WebFetch(*)",
            "WebSearch(*)"
        )
    }
    $settings | Add-Member -NotePropertyName "permissions" -NotePropertyValue $permissions -Force

    $plugins = New-Object PSCustomObject
    $plugins | Add-Member -NotePropertyName "superpowers@claude-plugins-official"          -NotePropertyValue $true
    $plugins | Add-Member -NotePropertyName "frontend-design@claude-plugins-official"      -NotePropertyValue $true
    $plugins | Add-Member -NotePropertyName "context7@claude-plugins-official"             -NotePropertyValue $true
    $plugins | Add-Member -NotePropertyName "claude-md-management@claude-plugins-official" -NotePropertyValue $true
    $plugins | Add-Member -NotePropertyName "session-report@claude-plugins-official"       -NotePropertyValue $true
    $plugins | Add-Member -NotePropertyName "security-guidance@claude-plugins-official"    -NotePropertyValue $true
    $settings | Add-Member -NotePropertyName "enabledPlugins" -NotePropertyValue $plugins -Force

    $marketplace = [PSCustomObject]@{
        'claude-plugins-official' = [PSCustomObject]@{
            source = [PSCustomObject]@{ source = "github"; repo = "anthropics/claude-plugins-official" }
        }
    }
    $settings | Add-Member -NotePropertyName "extraKnownMarketplaces" -NotePropertyValue $marketplace -Force

    [System.IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 10), $utf8NoBom)
    Write-OK "Permissions and plugins configured"
} else {
    Write-Host "  settings.json not found, skipping" -ForegroundColor Yellow
}

$bitrix24Dir = "C:\bitrix24"
if (-not (Test-Path $bitrix24Dir)) { New-Item -ItemType Directory -Force $bitrix24Dir | Out-Null }
@'
# Bitrix24 — iTech org context

Portal: itechkg.bitrix24.kz

## Behavior rules
- Use MCP tools directly — no confirmation between steps, no "shall I proceed?"
- Unknown user? Call bitrix24_find_user first, then continue immediately
- Short responses: show result, not the process
- If unsure what data exists — query it (bitrix24_list_*, bitrix24_get_*), don't guess
- Chain tool calls in one turn when possible

## MCP servers and access levels

### bitrix24 (employee webhook)
Scope: Tasks, CRM (read), Users
- Read/create/update/delete own tasks and tasks where responsible
- Read deals, contacts, companies, leads
- Find users by name or email

### bitrix24-admin (admin webhook)
Scope: Full access
- Everything above plus:
- Create/update/delete any CRM entity (deals, contacts, companies, leads)
- Full user management
- Reports, analytics, sales forecasts
- Business processes, activity monitoring

## Available MCP tools

### Tasks
bitrix24_create_task — create task (title, description, responsible_id, deadline)
bitrix24_get_task(id) — get task details
bitrix24_update_task(id, fields) — update task fields
bitrix24_delete_task(id) — delete task
bitrix24_list_tasks(filter) — list tasks with filters

### CRM — Deals
bitrix24_create_deal / get_deal / update_deal / list_deals
bitrix24_get_latest_deals — recent deals
bitrix24_get_deals_from_date_range — deals by period
bitrix24_get_deals_with_user_names — deals with resolved names
bitrix24_filter_deals_by_status / by_pipeline / by_budget
bitrix24_get_deal_stages — all stage IDs and names
bitrix24_get_deal_pipelines — all pipeline IDs and names
bitrix24_track_deal_progression — deal movement history

### CRM — Contacts
bitrix24_create_contact / get_contact / update_contact / list_contacts
bitrix24_get_latest_contacts / get_contacts_with_user_names

### CRM — Companies
bitrix24_create_company / get_company / update_company / list_companies
bitrix24_get_latest_companies / get_companies_with_user_names

### CRM — Leads
bitrix24_create_lead / get_lead / update_lead / list_leads
bitrix24_get_latest_leads / get_leads_with_user_names / get_leads_from_date_range

### Users
bitrix24_find_user(name_or_email) — find user by name or email
bitrix24_get_user(id) — get user details
bitrix24_get_all_users — list all portal users
bitrix24_resolve_user_names(ids) — batch resolve IDs to names

### Analytics & Reports
bitrix24_generate_sales_report — full sales report
bitrix24_get_team_dashboard — team KPIs
bitrix24_analyze_account_performance — account stats
bitrix24_analyze_customer_engagement — engagement metrics
bitrix24_compare_user_performance — compare managers
bitrix24_forecast_performance — sales forecast
bitrix24_get_user_performance_summary — single user summary
bitrix24_monitor_sales_activities — recent sales activity
bitrix24_monitor_user_activities — user activity log

### Search & Diagnostics
bitrix24_search_crm(query) — search across all CRM entities
bitrix24_check_crm_settings — portal CRM configuration
bitrix24_diagnose_permissions — check what current webhook can access
bitrix24_validate_webhook — test webhook connectivity

## Workflow patterns

### Find and update
1. bitrix24_find_user(name) -> get ID
2. bitrix24_list_tasks(responsible_id) -> find task
3. bitrix24_update_task(id, {status: 5}) -> done

### Create deal with contact
1. bitrix24_find_user(manager_name) -> responsible_id
2. bitrix24_create_contact(name, phone) -> contact_id
3. bitrix24_create_deal(title, contact_id, stage_id) -> deal_id

### Explore what's possible
- bitrix24_diagnose_permissions — see what this webhook can do
- bitrix24_check_crm_settings — see portal config
- bitrix24_get_deal_pipelines + get_deal_stages — see all stages

## Users

| ID | Name | Role |
|----|------|------|
| 1 | Chyngyz Usenov | - |
| 15 | Albina Aidakeeva | - |
| 17 | Japar Usenov | - |
| 27 | Beksultan Rakhmanov | Project Manager |
| 29 | Dastan Almazbekov | Project Manager |
| 35 | Nurdoolot Ermekbaev | Sales Manager |
| 45 | Nursultan Usupbaev | Logistics / Warehouse |
| 265 | Elmarbek Sadibakasov | Sales Manager |
| 273 | Ruslan Ibraimov | - |
| 281 | Viktor Artamonov | - |
| 659 | Bayel Mars uulu | Design / DevOps / IT |
| 661 | Renat Isaev | - |
| 663 | Evgeniya Sagaydak | - |
| 665 | Kubanychbek Abdulkhakim uulu | - |
| 667 | Guliza Teshebaeva | Office Manager |
| 669 | Azamat Imanturov | - |

## Task statuses

| Code | Meaning |
|------|---------|
| 1 | New |
| 2 | Pending |
| 3 | In progress |
| 5 | Completed |
| 6 | Deferred |
| 7 | Declined |

## CRM Pipelines and stages

### General (category_id=0)
| STAGE_ID | Name |
|----------|------|
| NEW | New request |
| UC_H9Y3H3 | New request Whatsapp |
| PREPARATION | Proposal preparation |
| PREPAYMENT_INVOICE | Proposal sent (awaiting confirmation) |
| EXECUTING | Contract / invoice |
| UC_9K5NM2 | Payment confirmed |
| UC_FJJ0GB | Tender |
| UC_CZIW12 | Next period |
| WON | Deal won |
| LOSE | Deal lost |
| APOLOGY | Loss analysis |

### Tender (category_id=1)
| STAGE_ID | Name |
|----------|------|
| C1:NEW | Tender selection |
| C1:PREPARATION | Tech solution approval |
| C1:PREPAYMENT_INVOICE | Price table preparation |
| C1:EXECUTING | Document submission |
| C1:FINAL_INVOICE | Contract |
| C1:WON | Deal won |
| C1:LOSE | Deal lost |

### Supply and Installation (category_id=3)
| STAGE_ID | Name |
|----------|------|
| C3:NEW | Equipment purchase |
| C3:PREPAYMENT_INVOICE | Installation estimate |
| C3:EXECUTING | Installation |
| C3:PREPARATION | ESF |
| C3:FINAL_INVOICE | Completion act |
| C3:WON | Deal won |
| C3:LOSE | Deal lost |

### CAC Projects (category_id=5)
| STAGE_ID | Name |
|----------|------|
| C5:NEW | New lead |
| C5:PREPARATION | Receiving TOR |
| C5:EXECUTING | Partner proposal |
| C5:FINAL_INVOICE | Client proposal |
| C5:UC_2Y6NRM | Proposal delivered |
| C5:PREPAYMENT_INVOICE | Vendor price negotiation |
| C5:UC_PCWEKU | Contract negotiation |
| C5:UC_VQ4PIY | Invoice / payment / SO launch |
| C5:WON | Deal won |
| C5:LOSE | Deal lost |

### CAC Design (category_id=9)
| STAGE_ID | Name |
|----------|------|
| C9:NEW | Awaiting acceptance |
| C9:PREPARATION | Passed to designer |
| C9:EXECUTING | Passed for proposal |
| C9:WON | Deal won |
| C9:LOSE | Deal lost |

### AV Service (category_id=13)
| STAGE_ID | Name |
|----------|------|
| C13:NEW | Service request |
| C13:PREPARATION | Remote / on-site diagnostics |
| C13:PREPAYMENT_INVOIC | Parts / firmware selection |
| C13:EXECUTING | Installation / setup |
| C13:UC_8PK6L3 | Handover / payment |
| C13:UC_2XY1DV | Post-service support |
| C13:WON | Deal won |
| C13:LOSE | Deal lost |

### AC Service (category_id=15)
| STAGE_ID | Name |
|----------|------|
| C15:NEW | New request |
| C15:PREPARATION | Diagnostics / measurement |
| C15:PREPAYMENT_INVOIC | Estimate and proposal |
| C15:EXECUTING | Awaiting parts / warehouse |
| C15:FINAL_INVOICE | Service work (installation) |
| C15:UC_L8KUBG | Quality control / payment |
| C15:WON | Deal won |
| C15:LOSE | Deal lost |
'@ | Set-Content "$bitrix24Dir\CLAUDE.md" -Encoding UTF8
Write-OK "C:\bitrix24\CLAUDE.md created"

$globalClaude = "$env:USERPROFILE\.claude\CLAUDE.md"
$pointer = "`n## Bitrix24`nIf the task involves Bitrix24 (tasks, deals, CRM, users), read C:\bitrix24\CLAUDE.md for org context.`n"
if (Test-Path $globalClaude) {
    if (-not (Select-String -Path $globalClaude -Pattern "C:\\bitrix24\\CLAUDE" -Quiet)) {
        Add-Content $globalClaude $pointer -Encoding UTF8
    }
} else {
    Set-Content $globalClaude $pointer -Encoding UTF8
}
Write-OK "~\.claude\CLAUDE.md updated (Bitrix24 pointer)"

Write-Host "`n=== Done! ===" -ForegroundColor Cyan
Write-Host "  Run claude from C:\bitrix24 to load org context automatically." -ForegroundColor Cyan
Write-Host "Run: " -NoNewline; Write-Host "claude mcp list" -ForegroundColor White
if ($adminConfig) {
    Write-Host "Available: bitrix24, bitrix24-admin" -ForegroundColor Green
} else {
    Write-Host "Available: bitrix24" -ForegroundColor Green
}
