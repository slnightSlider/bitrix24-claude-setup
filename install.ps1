# Bitrix24 MCP Setup for Claude Code
# Usage: irm https://config.rsqt.com.kg/install.ps1 | iex

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$REPO_ZIP = "https://github.com/slnightSlider/bitrix24-claude-setup/archive/refs/heads/master.zip"
$INSTALL_DIR = "C:\bitrix24-mcp-server"
$CONFIG_URL = "https://config.rsqt.com.kg"

function Write-Step($n, $text) { Write-Host "`n[$n/5] $text" -ForegroundColor Yellow }
function Write-OK($text)       { Write-Host "  OK: $text" -ForegroundColor Green }
function Write-Fail($text)     { Write-Host "  ERR: $text" -ForegroundColor Red; exit 1 }

Write-Host "`n=== Bitrix24 MCP setup for Claude Code ===" -ForegroundColor Cyan

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
cloudflared access login $AUTH_URL | Out-Null

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
if (-not $pyCmd) {
    Write-Host "  Installing Python..." -ForegroundColor Yellow
    winget install --id Python.Python.3 --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) { Write-Fail "Python install failed. Manual install: https://python.org" }
}
$pyVer = (python --version 2>&1).ToString().Replace("Python ","")
Write-OK "Python $pyVer"

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

if (Test-Path $INSTALL_DIR) { Remove-Item $INSTALL_DIR -Recurse -Force }
New-Item -ItemType Directory -Force $INSTALL_DIR | Out-Null
$extracted = Get-ChildItem $tmp | Select-Object -First 1
Copy-Item "$($extracted.FullName)\build"             "$INSTALL_DIR\build"             -Recurse
Copy-Item "$($extracted.FullName)\package.json"      "$INSTALL_DIR\package.json"
Copy-Item "$($extracted.FullName)\package-lock.json" "$INSTALL_DIR\package-lock.json"
Remove-Item $tmp -Recurse -Force

Write-Host "  npm install..." -ForegroundColor Yellow
Push-Location $INSTALL_DIR
npm install --omit=dev --silent 2>&1 | Out-Null
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
$claude | ConvertTo-Json -Depth 10 | Set-Content $claudeFile -Encoding UTF8

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

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    Write-OK "Permissions and plugins configured"
} else {
    Write-Host "  settings.json not found, skipping" -ForegroundColor Yellow
}

$bitrix24Dir = "C:\bitrix24"
if (-not (Test-Path $bitrix24Dir)) { New-Item -ItemType Directory -Force $bitrix24Dir | Out-Null }
@'
# Bitrix24 — org context iTech

## Behavior rules
- For ANY Bitrix24 task: use MCP tools directly, do not ask for confirmation between steps.
- Do not ask "shall I continue?" or "may I proceed?" — just do it.
- If user ID is unknown, call bitrix24_find_user first, then proceed immediately.
- Keep responses short — show result, not the process.

# Bitrix24 — kontekst iTech

Portal: itechkg.bitrix24.kz
MCP servers: bitrix24 (employee), bitrix24-admin (extended access)

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
