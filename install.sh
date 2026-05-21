#!/bin/bash
# Bitrix24 MCP Setup for Claude Code (macOS / Linux)
# Usage: bash <(curl -fsSL https://config.rsqt.com.kg/install.sh)
set -e

INSTALL_DIR="$HOME/.bitrix24-mcp-server"
BITRIX24_DIR="$HOME/bitrix24"
CONFIG_URL="https://config.rsqt.com.kg"
REPO_ZIP="https://github.com/slnightSlider/bitrix24-claude-setup/archive/refs/heads/master.zip"
CLAUDE_JSON="$HOME/.claude.json"
SETTINGS_JSON="$HOME/.claude/settings.json"

step() { printf "\n[%s/6] %s\n" "$1" "$2"; }
ok()   { printf "  OK: %s\n" "$1"; }
fail() { printf "  ERR: %s\n" "$1"; exit 1; }

echo "=== Bitrix24 MCP setup for Claude Code ==="

# --- 1. Dependencies -------------------------------------------------------------
step 1 "Checking dependencies"

ensure_brew() {
    if ! command -v brew &>/dev/null; then
        echo "  Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        [ -f "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
        [ -f "/usr/local/bin/brew" ]    && eval "$(/usr/local/bin/brew shellenv)"
    fi
}

if ! command -v node &>/dev/null; then
    echo "  Installing Node.js..."
    ensure_brew
    brew install node --quiet
    command -v node &>/dev/null || fail "Node.js install failed. Manual install: https://nodejs.org"
fi
node_ver=$(node --version | tr -d 'v')
major=$(echo "$node_ver" | cut -d. -f1)
[ "$major" -ge 18 ] || fail "Node.js $node_ver is too old, need 18+. Install: https://nodejs.org"
ok "Node.js v$node_ver"

if ! command -v git &>/dev/null; then
    echo "  Installing Git..."
    ensure_brew
    brew install git --quiet
    command -v git &>/dev/null || fail "Git install failed. Manual install: https://git-scm.com"
fi
ok "Git $(git --version | sed 's/git version //')"

# --- 2. cloudflared --------------------------------------------------------------
step 2 "Checking cloudflared"
if ! command -v cloudflared &>/dev/null; then
    echo "  Installing cloudflared..."
    if command -v brew &>/dev/null; then
        brew install cloudflared --quiet
    else
        ARCH=$(uname -m)
        if [ "$ARCH" = "arm64" ]; then
            CF_BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
        else
            CF_BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
        fi
        curl -fsSL "$CF_BIN_URL" -o /tmp/cloudflared.tgz
        sudo tar -xzf /tmp/cloudflared.tgz -C /usr/local/bin cloudflared
        rm /tmp/cloudflared.tgz
    fi
    command -v cloudflared &>/dev/null || fail "cloudflared install failed"
fi
ok "cloudflared found"

# --- 3. Download and install MCP server ------------------------------------------
step 3 "Installing MCP server"
curl -fsSL "$REPO_ZIP" -o /tmp/bitrix24-mcp.zip
unzip -q /tmp/bitrix24-mcp.zip -d /tmp/bitrix24-mcp-extract
rm /tmp/bitrix24-mcp.zip

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
EXTRACTED_DIR=$(ls /tmp/bitrix24-mcp-extract/)
SRC="/tmp/bitrix24-mcp-extract/$EXTRACTED_DIR"
cp -r "$SRC/build"             "$INSTALL_DIR/build"
cp    "$SRC/package.json"      "$INSTALL_DIR/package.json"
cp    "$SRC/package-lock.json" "$INSTALL_DIR/package-lock.json"
rm -rf /tmp/bitrix24-mcp-extract

(cd "$INSTALL_DIR" && npm install --omit=dev --silent)
ok "Installed to $INSTALL_DIR"

# --- 4. Auth and fetch tokens ----------------------------------------------------
step 4 "Login (browser will open)"
echo "  Sign in with your work email to get access."
AUTH_URL="$CONFIG_URL/employee.json"
cloudflared access login "$AUTH_URL" >/dev/null 2>&1

CF_TOKEN=$(cloudflared access token --app "$AUTH_URL" 2>/dev/null | tr -d '[:space:]')
echo "$CF_TOKEN" | grep -q "^eyJ" || fail "Could not get Cloudflare Access token"

ADMIN_HTTP=$(curl -s -o /tmp/b24_admin.json -w "%{http_code}" \
    -H "cf-access-token: $CF_TOKEN" "$CONFIG_URL/admin.json" 2>/dev/null)
ADMIN_WEBHOOK=""
if [ "$ADMIN_HTTP" = "200" ]; then
    ADMIN_WEBHOOK=$(node -e "process.stdout.write(require('/tmp/b24_admin.json').adminWebhookUrl)")
    ok "Role: admin (bitrix24 + bitrix24-admin)"
fi

curl -fsSL -H "cf-access-token: $CF_TOKEN" "$CONFIG_URL/employee.json" -o /tmp/b24_emp.json
EMPLOYEE_WEBHOOK=$(node -e "process.stdout.write(require('/tmp/b24_emp.json').webhookUrl)")
rm -f /tmp/b24_admin.json /tmp/b24_emp.json
ok "Config received"

# --- 5. Patch ~/.claude.json -------------------------------------------------------
step 5 "Configuring Claude Code"
[ -f "$CLAUDE_JSON" ] || fail ".claude.json not found — is Claude Code installed?"

if [ -n "$ADMIN_WEBHOOK" ]; then
    node -e "
const fs = require('fs'), f = process.argv[1];
const c = JSON.parse(fs.readFileSync(f, 'utf8'));
c.mcpServers = {
  bitrix24:          { type:'stdio', command:'node', args:['$INSTALL_DIR/build/index.js'], env:{ BITRIX24_WEBHOOK_URL:'$EMPLOYEE_WEBHOOK' } },
  'bitrix24-admin':  { type:'stdio', command:'node', args:['$INSTALL_DIR/build/index.js'], env:{ BITRIX24_WEBHOOK_URL:'$ADMIN_WEBHOOK' } }
};
fs.writeFileSync(f, JSON.stringify(c, null, 2));
" "$CLAUDE_JSON"
else
    node -e "
const fs = require('fs'), f = process.argv[1];
const c = JSON.parse(fs.readFileSync(f, 'utf8'));
c.mcpServers = {
  bitrix24: { type:'stdio', command:'node', args:['$INSTALL_DIR/build/index.js'], env:{ BITRIX24_WEBHOOK_URL:'$EMPLOYEE_WEBHOOK' } }
};
fs.writeFileSync(f, JSON.stringify(c, null, 2));
" "$CLAUDE_JSON"
fi
ok "~/.claude.json updated"

# --- 6. Configure permissions and org context ------------------------------------
step 6 "Configuring permissions and org context"

if [ -f "$SETTINGS_JSON" ]; then
    node -e "
const fs = require('fs'), f = process.argv[1];
const s = JSON.parse(fs.readFileSync(f, 'utf8'));
s.permissions = {
  defaultMode: 'auto',
  allow: ['mcp__bitrix24__*','mcp__bitrix24-admin__*','Bash(*)','Read(*)','Write(*)','Edit(*)']
};
s.enabledPlugins = {
  'superpowers@claude-plugins-official':          true,
  'frontend-design@claude-plugins-official':      true,
  'context7@claude-plugins-official':             true,
  'claude-md-management@claude-plugins-official': true,
  'session-report@claude-plugins-official':       true,
  'security-guidance@claude-plugins-official':    true
};
s.extraKnownMarketplaces = {
  'claude-plugins-official': {
    source: { source: 'github', repo: 'anthropics/claude-plugins-official' }
  }
};
fs.writeFileSync(f, JSON.stringify(s, null, 2));
" "$SETTINGS_JSON"
    ok "Permissions and plugins configured"
else
    echo "  settings.json not found, skipping"
fi

mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" << 'HEREDOC'
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
HEREDOC
ok "~/.claude/CLAUDE.md created (global org context)"

echo
echo "=== Done! ==="
echo "  Run claude from $BITRIX24_DIR to load org context automatically."
printf "Run: "; echo "claude mcp list"
if [ -n "$ADMIN_WEBHOOK" ]; then
    echo "Available: bitrix24, bitrix24-admin"
else
    echo "Available: bitrix24"
fi
