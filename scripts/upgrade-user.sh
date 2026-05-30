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
TAG=""
BACKUP_DIR="${HOME}/.zeroclaw/backups"
BACKUP_NAME=""
BACKUP_WEB_DIST_NAME=""

# ── Cleanup state ────────────────────────────────────────────────────────────
CLEANUP_DONE=0

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi
    CLEANUP_DONE=1
    rm -rf /tmp/zeroclaw-upgrade /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums 2>/dev/null || true
}
trap cleanup EXIT

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  upgrade-user.sh --tag <tag>

${BOLD}Required:${NC}
  --tag <tag>    Release tag to install (e.g. v0.8.0-beta-2)

${BOLD}Optional:${NC}
  --help         Show this help message

${BOLD}Example:${NC}
  ssh cosita@vps './upgrade-user.sh --tag v0.8.0-beta-2'
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)  TAG="$2"; shift 2 ;;
        --help) usage ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            exit 1
            ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$TAG" ]]; then
    echo -e "${RED}Error: --tag is required.${NC}" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

if [[ ! "$TAG" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo -e "${RED}Error: Invalid tag format '${TAG}'${NC}" >&2
    exit 1
fi

# Architecture guard — only x86_64 tarball available
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    echo -e "${RED}❌ Architecture is ${ARCH}, but only x86_64 tarball is available.${NC}" >&2
    exit 1
fi

TARBALL_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz"
SHA256_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/SHA256SUMS"
EXTRACT_DIR="/tmp/zeroclaw-upgrade"

# ── Phase 1: Download + verify ───────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 1: Download + Verify ═══${NC}"
echo -e "Tag: ${BOLD}${TAG}${NC}"

echo -e "${YELLOW}▸ Downloading release tarball...${NC}"
if ! curl -fsSL -o /tmp/zeroclaw-upgrade.tar.gz "${TARBALL_URL}"; then
    echo -e "${RED}❌ Download failed. Check that tag '${TAG}' exists.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Download complete${NC}"

# Checksum verification
echo -e "${YELLOW}▸ Downloading SHA256SUMS...${NC}"
if curl -fsSL -o /tmp/zeroclaw-sha256sums "${SHA256_URL}" 2>/dev/null; then
    EXPECTED=$(grep 'zeroclaw-x86_64-unknown-linux-gnu.tar.gz' /tmp/zeroclaw-sha256sums | awk '{print $1}')
    ACTUAL=$(sha256sum /tmp/zeroclaw-upgrade.tar.gz | awk '{print $1}')
    if [[ "$EXPECTED" == "$ACTUAL" ]]; then
        echo -e "${GREEN}✓ Checksum verified${NC}"
    else
        echo -e "${RED}❌ Checksum verification failed! Aborting.${NC}" >&2
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ SHA256SUMS not available — skipping verification${NC}"
fi

echo -e "${YELLOW}▸ Extracting to ${EXTRACT_DIR}/...${NC}"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf /tmp/zeroclaw-upgrade.tar.gz -C "${EXTRACT_DIR}"
echo -e "${GREEN}✓ Extraction complete${NC}"

# ── Phase 2: Backup ─────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 2: Backup ═══${NC}"

# Find actual binary path from systemd user service
_EXEC_RAW="$(systemctl --user show zeroclaw -p ExecStart 2>/dev/null || true)"
# Extract value after ExecStart= prefix, strip JSON braces, take first token
INSTALL_PATH="$(echo "$_EXEC_RAW" | sed 's/^ExecStart=//' | tr -d '{}' | awk '{print $1}')"
if [[ -n "$INSTALL_PATH" ]]; then
    echo -e "${CYAN}Service binary path: ${INSTALL_PATH}${NC}"
else
    INSTALL_PATH="${HOME}/.cargo/bin/zeroclaw"
    echo -e "${YELLOW}⚠ Could not determine service binary path — using default: ${INSTALL_PATH}${NC}"
fi

mkdir -p "${BACKUP_DIR}"

# Back up existing binary
BACKUP_NAME="zeroclaw-$(date +%Y%m%d%H%M%S)-${RANDOM}"
echo -e "${YELLOW}▸ Backing up existing binary...${NC}"
if [[ -f "$INSTALL_PATH" ]]; then
    cp "$INSTALL_PATH" "${BACKUP_DIR}/${BACKUP_NAME}"
    echo -e "${GREEN}✓ Backup saved to ${BACKUP_DIR}/${BACKUP_NAME}${NC}"
else
    echo -e "${YELLOW}⚠ No existing binary to back up${NC}"
fi

# Back up existing web dist
WEB_DIST_DIR="${HOME}/.local/share/zeroclaw/web/dist"
BACKUP_WEB_DIST_NAME="${BACKUP_NAME}-web-dist"
echo -e "${YELLOW}▸ Backing up existing web dist...${NC}"
if [[ -d "$WEB_DIST_DIR" ]]; then
    cp -r "$WEB_DIST_DIR" "${BACKUP_DIR}/${BACKUP_WEB_DIST_NAME}"
    echo -e "${GREEN}✓ Web dist backup saved to ${BACKUP_DIR}/${BACKUP_WEB_DIST_NAME}${NC}"
else
    echo -e "${YELLOW}⚠ No existing web dist to back up${NC}"
    BACKUP_WEB_DIST_NAME=""
fi

# ── Phase 3: Install ────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 3: Install ═══${NC}"

# Install binary
echo -e "${YELLOW}▸ Installing binary...${NC}"
INSTALL_DIR="$(dirname "$INSTALL_PATH")"
mkdir -p "$INSTALL_DIR"
cp "${EXTRACT_DIR}/zeroclaw" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"
echo -e "${GREEN}✓ Binary installed to ${INSTALL_PATH}${NC}"

# Install web dist
echo -e "${YELLOW}▸ Installing web dist...${NC}"
WEB_PARENT="$(dirname "$WEB_DIST_DIR")"
mkdir -p "$WEB_PARENT"
rm -rf "$WEB_DIST_DIR"
cp -r "${EXTRACT_DIR}/web/dist" "$WEB_DIST_DIR"
echo -e "${GREEN}✓ Web dist installed${NC}"

# ── Phase 4: Config ─────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 4: Config ═══${NC}"

CONFIG_PATH="${HOME}/.zeroclaw/config.toml"
if [[ ! -f "$CONFIG_PATH" ]]; then
    echo -e "${YELLOW}⚠ config.toml not found — skipping config update${NC}"
else
    HAS_KEY=$(grep -c 'process_audio_without_transcription' "$CONFIG_PATH" 2>/dev/null || true)
    HAS_KEY=${HAS_KEY:-0}
    if [[ "$HAS_KEY" -gt 0 ]]; then
        echo -e "${GREEN}✓ process_audio_without_transcription already present${NC}"
    else
        echo -e "${YELLOW}▸ Adding process_audio_without_transcription...${NC}"
        cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%s)-${RANDOM}"

        HAS_SECTION=$(grep -c '^\[channels\.telegram\.default\]' "$CONFIG_PATH" 2>/dev/null || true)
        HAS_SECTION=${HAS_SECTION:-0}
        if [[ "$HAS_SECTION" -gt 0 ]]; then
            # Insert key after existing section header
            sed -i '/^\[channels\.telegram\.default\]/a process_audio_without_transcription = true' "$CONFIG_PATH"
        else
            # Append new section
            cat >> "$CONFIG_PATH" <<'TOML'

[channels.telegram.default]
process_audio_without_transcription = true
TOML
        fi
        echo -e "${GREEN}✓ Config updated${NC}"
    fi
fi

# ── Phase 5: Restart ────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 5: Restart ═══${NC}"

# Check and enable linger if needed (users can enable their own linger)
LINGER=$(loginctl show-user "$(whoami)" -p Linger --value 2>/dev/null || echo 'unknown')
if [[ "$LINGER" != "yes" ]]; then
    echo -e "${YELLOW}▸ Enabling linger for systemd --user...${NC}"
    loginctl enable-linger "$(whoami)"
    echo -e "${GREEN}✓ Linger enabled${NC}"
else
    echo -e "${GREEN}✓ Linger already enabled${NC}"
fi

# Check if systemd user service exists
SVC_EXISTS=$(systemctl --user status zeroclaw &>/dev/null && echo yes || echo no)
if [[ "$SVC_EXISTS" == "no" ]]; then
    echo -e "${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
else
    echo -e "${YELLOW}▸ Restarting zeroclaw service...${NC}"
    systemctl --user restart zeroclaw
    echo -e "${GREEN}✓ Service restarted${NC}"
fi

# ── Phase 6: Cleanup + summary ──────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 6: Cleanup + Summary ═══${NC}"
rm -rf "${EXTRACT_DIR}" /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums
echo -e "${GREEN}✓ Temporary files removed${NC}"

echo -e "\n${CYAN}${BOLD}═══ Summary ═══${NC}"
echo -e "  ${GREEN}Installed version:${NC} ${TAG}"
echo -e "  ${GREEN}Binary:${NC} ${INSTALL_PATH}"
echo -e "  ${GREEN}Backup (binary):${NC} ${BACKUP_DIR}/${BACKUP_NAME}"
if [[ -n "$BACKUP_WEB_DIST_NAME" ]]; then
    echo -e "  ${GREEN}Backup (web dist):${NC} ${BACKUP_DIR}/${BACKUP_WEB_DIST_NAME}"
fi
echo -e "\n  ${CYAN}To rollback:${NC}"
echo -e "  ./scripts/rollback-user.sh --backup-path ${BACKUP_DIR}/${BACKUP_NAME}"
echo ""
