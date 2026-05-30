#!/usr/bin/env bash
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
BACKUP_PATH=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  rollback-user.sh --backup-path <path>

${BOLD}Required:${NC}
  --backup-path <path>   Full path to the backed-up zeroclaw binary

${BOLD}Optional:${NC}
  --help                 Show this help message

${BOLD}Example:${NC}
  rollback-user.sh --backup-path ~/.zeroclaw/backups/zeroclaw-20240101120000-12345
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-path) BACKUP_PATH="$2"; shift 2 ;;
        --help)        usage ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            exit 1
            ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$BACKUP_PATH" ]]; then
    echo -e "${RED}Error: --backup-path is required.${NC}" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

if [[ ! -f "$BACKUP_PATH" ]]; then
    echo -e "${RED}❌ Backup binary not found at '${BACKUP_PATH}'${NC}" >&2
    exit 1
fi

# ── Phase 1: Restore binary ─────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Rollback ═══${NC}"
echo -e "Backup: ${BOLD}${BACKUP_PATH}${NC}"

# Find actual binary path from systemd user service
INSTALL_PATH="$(systemctl --user show zeroclaw -p ExecStart --value 2>/dev/null | awk '{print $1}')"
if [[ -n "$INSTALL_PATH" ]]; then
    echo -e "${CYAN}Service binary path: ${INSTALL_PATH}${NC}"
else
    INSTALL_PATH="${HOME}/.cargo/bin/zeroclaw"
    echo -e "${YELLOW}⚠ Could not determine service binary path — using default: ${INSTALL_PATH}${NC}"
fi

echo -e "${YELLOW}▸ Restoring binary...${NC}"
INSTALL_DIR="$(dirname "$INSTALL_PATH")"
mkdir -p "$INSTALL_DIR"
cp "$BACKUP_PATH" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"
echo -e "${GREEN}✓ Binary restored to ${INSTALL_PATH}${NC}"

# ── Phase 2: Restore web dist ───────────────────────────────────────────────
WEB_DIST_BACKUP="${BACKUP_PATH}-web-dist"
if [[ -d "$WEB_DIST_BACKUP" ]]; then
    echo -e "${YELLOW}▸ Restoring web dist...${NC}"
    WEB_DIST_DIR="${HOME}/.local/share/zeroclaw/web/dist"
    WEB_PARENT="$(dirname "$WEB_DIST_DIR")"
    mkdir -p "$WEB_PARENT"
    rm -rf "$WEB_DIST_DIR"
    cp -r "$WEB_DIST_BACKUP" "$WEB_DIST_DIR"
    echo -e "${GREEN}✓ Web dist restored${NC}"
else
    echo -e "${YELLOW}⚠ No web dist backup found — skipping${NC}"
fi

# ── Phase 3: Restart ────────────────────────────────────────────────────────
echo -e "${YELLOW}▸ Restarting zeroclaw service...${NC}"

SVC_EXISTS=$(systemctl --user status zeroclaw &>/dev/null && echo yes || echo no)
if [[ "$SVC_EXISTS" == "no" ]]; then
    echo -e "${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
else
    systemctl --user restart zeroclaw
    echo -e "${GREEN}✓ Service restarted${NC}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}${BOLD}✅ Rollback complete${NC}"
echo -e "  ${GREEN}Binary:${NC} ${INSTALL_PATH}"
echo -e "  ${GREEN}Restored from:${NC} ${BACKUP_PATH}"
echo -e "\n  ${CYAN}To upgrade again:${NC}"
echo -e "  ./scripts/upgrade-user.sh --tag <tag>"
echo ""
