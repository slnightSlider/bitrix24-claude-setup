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

Write-Host "`n=== Bitrix24 MCP — установка для Claude Code ===" -ForegroundColor Cyan

# ─── 1. Node.js ───────────────────────────────────────────────────────────────
Write-Step 1 "Проверка Node.js"
try {
    $raw = node --version 2>&1
    $ver = $raw.ToString().TrimStart('v')
    $major = [int]($ver.Split('.')[0])
    if ($major -lt 18) { Write-Fail "Node.js $ver — нужна версия 18+. Скачай: https://nodejs.org" }
    Write-OK "Node.js v$ver"
} catch {
    Write-Fail "Node.js не найден. Установи: https://nodejs.org"
}

# ─── 2. cloudflared ───────────────────────────────────────────────────────────
Write-Step 2 "Проверка cloudflared"
$cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
$cfPath = if ($cfCmd) { $cfCmd.Source } else { $null }
if (-not $cfPath) {
    Write-Host "  Устанавливаю cloudflared..." -ForegroundColor Yellow
    winget install --id Cloudflare.cloudflared --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    $cfPath = if ($cfCmd) { $cfCmd.Source } else { $null }
    if (-not $cfPath) { Write-Fail "cloudflared не установился. Установи вручную: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" }
}
Write-OK "cloudflared найден"

# ─── 3. Скачать и установить MCP сервер ──────────────────────────────────────
Write-Step 3 "Установка MCP сервера"
$zip = "$env:TEMP\bitrix24-mcp.zip"
Invoke-WebRequest $REPO_ZIP -OutFile $zip
$tmp = "$env:TEMP\bitrix24-mcp-extract"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip -DestinationPath $tmp
Remove-Item $zip

if (Test-Path $INSTALL_DIR) { Remove-Item $INSTALL_DIR -Recurse -Force }
New-Item -ItemType Directory -Force $INSTALL_DIR | Out-Null
$extracted = Get-ChildItem $tmp | Select-Object -First 1
Copy-Item "$($extracted.FullName)\build"        "$INSTALL_DIR\build"        -Recurse
Copy-Item "$($extracted.FullName)\package.json" "$INSTALL_DIR\package.json"
Copy-Item "$($extracted.FullName)\package-lock.json" "$INSTALL_DIR\package-lock.json"
Remove-Item $tmp -Recurse -Force

Write-Host "  npm install..." -ForegroundColor Yellow
Push-Location $INSTALL_DIR
npm install --omit=dev --silent 2>&1 | Out-Null
Pop-Location
Write-OK "Установлено в $INSTALL_DIR"

# ─── 4. Авторизация и получение токенов ──────────────────────────────────────
Write-Step 4 "Авторизация (откроется браузер)"
Write-Host "  Войди через свой email — это даст доступ к конфигу." -ForegroundColor Cyan
cloudflared access login $CONFIG_URL 2>&1 | Out-Null

$cfToken = (cloudflared access token --app $CONFIG_URL 2>&1).ToString().Trim()
if (-not $cfToken -or $cfToken -like "*error*") { Write-Fail "Не удалось получить токен Cloudflare Access" }

$headers = @{ "cf-access-token" = $cfToken }

$adminConfig = $null
try {
    $adminConfig = Invoke-RestMethod "$CONFIG_URL/admin.json" -Headers $headers -ErrorAction Stop
    Write-OK "Роль: admin (bitrix24 + bitrix24-admin)"
} catch {}

$empConfig = Invoke-RestMethod "$CONFIG_URL/employee.json" -Headers $headers
Write-OK "Конфиг получен"

# ─── 5. Патч .claude.json ─────────────────────────────────────────────────────
Write-Step 5 "Настройка Claude Code"
$claudeFile = "$env:USERPROFILE\.claude.json"
if (-not (Test-Path $claudeFile)) { Write-Fail ".claude.json не найден — установлен ли Claude Code?" }

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

$claude.mcpServers = $mcp
$claude | ConvertTo-Json -Depth 10 | Set-Content $claudeFile -Encoding UTF8

Write-Host "`n=== Готово! ===" -ForegroundColor Cyan
Write-Host "Проверь: " -NoNewline; Write-Host "claude mcp list" -ForegroundColor White
if ($adminConfig) {
    Write-Host "Доступны: bitrix24, bitrix24-admin" -ForegroundColor Green
} else {
    Write-Host "Доступен: bitrix24" -ForegroundColor Green
}
