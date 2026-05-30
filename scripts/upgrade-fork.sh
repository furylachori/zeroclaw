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
HOST=""
SSH_USER=""
USERS=""
TAG="latest"
SSH_KEY=""
SUCCESS_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0
LAST_BACKUP_NAME=""
declare -a RESULTS=()

# ── Escape single quotes for safe embedding in remote shell commands ─────────
sq() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  upgrade-fork.sh --host <vps-host> --user <ssh-user> --users <user1,user2,...> [OPTIONS]

${BOLD}Required:${NC}
  --host <host>       VPS hostname or IP address
  --user <user>       SSH user for the VPS
  --users <list>      Comma-separated list of zeroclaw user accounts on the VPS

${BOLD}Optional:${NC}
  --tag <tag>         Release tag to deploy (default: latest)
  --key <path>        Path to SSH private key (uses default if omitted)
  --help              Show this help message

${BOLD}Example:${NC}
  upgrade-fork.sh --host vps.example.com --user root --users cosita,espinas,fury --tag v0.3.1
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  HOST="$2";     shift 2 ;;
        --user)  SSH_USER="$2"; shift 2 ;;
        --users) USERS="$2";    shift 2 ;;
        --tag)   TAG="$2";      shift 2 ;;
        --key)   SSH_KEY="$2";  shift 2 ;;
        --help)  usage ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            exit 1
            ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$HOST" || -z "$SSH_USER" || -z "$USERS" ]]; then
    echo -e "${RED}Error: --host, --user, and --users are required.${NC}" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

# [C-1] Validate tag format to prevent command injection
if [[ ! "$TAG" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo -e "${RED}Error: Invalid tag format '${TAG}'${NC}" >&2
    exit 1
fi

# [H-1] accept-new auto-accepts NEW keys but rejects CHANGED keys
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

TARBALL_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz"
SHA256_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/SHA256SUMS"
REMOTE_DIR="/tmp/zeroclaw-upgrade"

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    # shellcheck disable=SC2086
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo rm -rf '${REMOTE_DIR}' /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums" 2>/dev/null || true
}
trap cleanup EXIT

# ── Helper: run command on VPS ───────────────────────────────────────────────
remote() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$@"
}

# ── Phase 1: Download ───────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 1: Download ═══${NC}"
echo -e "Host: ${BOLD}${HOST}${NC}  Tag: ${BOLD}${TAG}${NC}"

echo -e "${YELLOW}▸ Testing SSH connection...${NC}"
if ! remote "true"; then
    echo -e "${RED}❌ SSH connection to ${SSH_USER}@${HOST} failed.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ SSH connection OK${NC}"

# [M-1] Check sudo access — prevents silent hang
echo -e "${YELLOW}▸ Checking sudo access...${NC}"
if ! remote "sudo -n true" 2>/dev/null; then
    echo -e "${RED}Error: SSH user '${SSH_USER}' requires a password for sudo.${NC}" >&2
    echo "Configure NOPASSWD in /etc/sudoers for this user." >&2
    exit 1
fi
echo -e "${GREEN}✓ sudo access OK${NC}"

# [M-7] Architecture guard — only x86_64 tarball available
REMOTE_ARCH="$(remote "uname -m")"
if [[ "$REMOTE_ARCH" != "x86_64" ]]; then
    echo -e "${RED}❌ VPS architecture is ${REMOTE_ARCH}, but only x86_64 tarball is available.${NC}" >&2
    exit 1
fi

echo -e "${YELLOW}▸ Downloading release tarball...${NC}"
if ! remote "curl -fsSL -o /tmp/zeroclaw-upgrade.tar.gz '${TARBALL_URL}'"; then
    echo -e "${RED}❌ Download failed. Check that tag '${TAG}' exists.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Download complete${NC}"

# ── Phase 1b: Checksum verification ─────────────────────────────────────────
# [C-2] Extract hash and compare manually to handle filename mismatch
echo -e "${YELLOW}▸ Downloading SHA256SUMS...${NC}"
if remote "curl -fsSL -o /tmp/zeroclaw-sha256sums '${SHA256_URL}'"; then
    EXPECTED=$(remote "grep 'zeroclaw-x86_64-unknown-linux-gnu.tar.gz' /tmp/zeroclaw-sha256sums | awk '{print \$1}'")
    ACTUAL=$(remote "sha256sum /tmp/zeroclaw-upgrade.tar.gz | awk '{print \$1}'")
    if [[ "$EXPECTED" == "$ACTUAL" ]]; then
        echo -e "${GREEN}✓ Checksum verified${NC}"
    else
        echo -e "${RED}❌ Checksum verification failed! Aborting.${NC}" >&2
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ SHA256SUMS not available — skipping verification${NC}"
fi

echo -e "${YELLOW}▸ Extracting to ${REMOTE_DIR}/...${NC}"
remote "rm -rf '${REMOTE_DIR}' && mkdir -p '${REMOTE_DIR}' && tar -xzf /tmp/zeroclaw-upgrade.tar.gz -C '${REMOTE_DIR}'"
echo -e "${GREEN}✓ Extraction complete${NC}"

# ── Phase 2: Distribute ─────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 2: Distribute ═══${NC}"

IFS=',' read -ra USER_LIST <<< "$USERS"

for user in "${USER_LIST[@]}"; do
    user="$(echo "$user" | xargs)"  # trim whitespace
    echo -e "\n${BOLD}── User: ${user} ──${NC}"
    STATUS="ok"

    # Validate username format to prevent command injection
    if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo -e "  ${RED}❌ Invalid username format: '${user}'${NC}"
        RESULTS+=("${user}: ❌ error (invalid username)")
        ((ERROR_COUNT++)) || true
        continue
    fi

    # Verify user exists on the VPS
    if ! remote "id '$(sq "$user")' &>/dev/null"; then
        echo -e "  ${RED}❌ User '${user}' does not exist on VPS${NC}"
        RESULTS+=("${user}: ❌ error (user not found)")
        ((ERROR_COUNT++)) || true
        continue
    fi

    USER_HOME="$(remote "getent passwd '$(sq "$user")' | cut -d: -f6")"

    # [M-5] Read actual binary path from the service unit
    INSTALL_PATH="$(remote "sudo -u '$(sq "$user")' env XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user show zeroclaw -p ExecStart --value 2>/dev/null | awk '{print \$1}'")"
    if [[ -n "$INSTALL_PATH" ]]; then
        echo -e "  ${CYAN}Service binary path: ${INSTALL_PATH}${NC}"
    else
        INSTALL_PATH="${USER_HOME}/.cargo/bin/zeroclaw"
        echo -e "  ${YELLOW}⚠ Could not determine service binary path — using default: ${INSTALL_PATH}${NC}"
    fi

    # ── Backup existing binary ──
    # [L-1] Add $RANDOM to avoid filename collision
    # [M-2] Use /var/lib/zeroclaw-backups/ instead of /tmp
    echo -e "  ${YELLOW}▸ Backing up existing binary...${NC}"
    BACKUP_NAME="zeroclaw-$(date +%Y%m%d%H%M%S)-${RANDOM}"
    LAST_BACKUP_NAME="$BACKUP_NAME"
    remote "sudo mkdir -p -m 0700 /var/lib/zeroclaw-backups && sudo cp '$(sq "$INSTALL_PATH")' '/var/lib/zeroclaw-backups/${BACKUP_NAME}' 2>/dev/null || echo 'no existing binary to back up'"
    echo -e "  ${GREEN}✓ Backup saved to /var/lib/zeroclaw-backups/${BACKUP_NAME}${NC}"

    # [M-6] Back up web/dist alongside the binary
    remote "sudo cp -r '$(sq "$USER_HOME")/.local/share/zeroclaw/web/dist' '/var/lib/zeroclaw-backups/${BACKUP_NAME}-web-dist' 2>/dev/null || echo 'no existing web dist to back up'"

    # ── Copy binary ──
    echo -e "  ${YELLOW}▸ Installing binary...${NC}"
    INSTALL_DIR="$(dirname "$INSTALL_PATH")"
    remote "sudo mkdir -p '$(sq "$INSTALL_DIR")' && sudo cp '${REMOTE_DIR}/zeroclaw' '$(sq "$INSTALL_PATH")' && sudo chmod 755 '$(sq "$INSTALL_PATH")' && sudo chown '$(sq "$user"):' '$(sq "$INSTALL_PATH")'"
    echo -e "  ${GREEN}✓ Binary installed${NC}"

    # ── Copy web dist ──
    echo -e "  ${YELLOW}▸ Installing web dist...${NC}"
    remote "sudo mkdir -p '$(sq "$USER_HOME")/.local/share/zeroclaw/web' && sudo rm -rf '$(sq "$USER_HOME")/.local/share/zeroclaw/web/dist' && sudo cp -r '${REMOTE_DIR}/web/dist' '$(sq "$USER_HOME")/.local/share/zeroclaw/web/dist' && sudo chown -R '$(sq "$user"):' '$(sq "$USER_HOME")/.local/share/zeroclaw/web'"
    echo -e "  ${GREEN}✓ Web dist installed${NC}"

    # ── Config update ──
    CONFIG_PATH="${USER_HOME}/.zeroclaw/config.toml"
    CONFIG_EXISTS="$(remote "sudo test -f '$(sq "$CONFIG_PATH")' && echo yes || echo no")"

    if [[ "$CONFIG_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ config.toml not found — skipping config update${NC}"
        STATUS="warn"
        ((WARN_COUNT++)) || true
    else
        HAS_KEY="$(remote "sudo grep -c 'process_audio_without_transcription' '$(sq "$CONFIG_PATH")' 2>/dev/null || echo 0")"
        if [[ "$HAS_KEY" -gt 0 ]]; then
            echo -e "  ${GREEN}✓ process_audio_without_transcription already present${NC}"
        else
            echo -e "  ${YELLOW}▸ Adding process_audio_without_transcription...${NC}"
            # [L-2] Add randomness to config backup filename (remote $RANDOM)
            remote "sudo cp '$(sq "$CONFIG_PATH")' \"$(sq "$CONFIG_PATH").bak.\$(date +%s)-\$RANDOM\""

            HAS_SECTION="$(remote "sudo grep -c '^\[channels\.telegram\.default\]' '$(sq "$CONFIG_PATH")' 2>/dev/null || echo 0")"
            if [[ "$HAS_SECTION" -gt 0 ]]; then
                # Insert key after existing section header
                remote "sudo sed -i '/^\[channels\.telegram\.default\]/a process_audio_without_transcription = true' '$(sq "$CONFIG_PATH")'"
            else
                # Append new section
                remote "sudo tee -a '$(sq "$CONFIG_PATH")' > /dev/null <<'TOML'

[channels.telegram.default]
process_audio_without_transcription = true
TOML"
            fi
            remote "sudo chown '$(sq "$user"):' '$(sq "$CONFIG_PATH")'"
            echo -e "  ${GREEN}✓ Config updated${NC}"
        fi
    fi

    # [M-4] Check and enable linger for systemd --user
    LINGER="$(remote "sudo loginctl show-user '$(sq "$user")' -p Linger --value 2>/dev/null || echo 'unknown'")"
    if [[ "$LINGER" != "yes" ]]; then
        echo -e "  ${YELLOW}⚠ User linger not enabled — enabling for systemd --user...${NC}"
        remote "sudo loginctl enable-linger '$(sq "$user")'"
    fi

    # ── Restart systemd service ──
    # [M-3] Wrap in env for reliable variable expansion with sudo -u
    SVC_EXISTS="$(remote "sudo -u '$(sq "$user")' env XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user status zeroclaw &>/dev/null && echo yes || echo no")"
    if [[ "$SVC_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
        if [[ "$STATUS" == "ok" ]]; then STATUS="warn"; fi
        ((WARN_COUNT++)) || true
    else
        echo -e "  ${YELLOW}▸ Restarting zeroclaw service...${NC}"
        remote "sudo -u '$(sq "$user")' env XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user restart zeroclaw"
        echo -e "  ${GREEN}✓ Service restarted${NC}"
    fi

    if [[ "$STATUS" == "ok" ]]; then
        echo -e "  ${GREEN}✅ ${user}: upgrade complete${NC}"
        RESULTS+=("${user}: ✅ success (backup: /var/lib/zeroclaw-backups/${BACKUP_NAME})")
        ((SUCCESS_COUNT++)) || true
    else
        echo -e "  ${YELLOW}⚠️  ${user}: upgrade complete with warnings${NC}"
        RESULTS+=("${user}: ⚠️  warning (check details above)")
    fi
done

# ── Phase 3: Cleanup ────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 3: Cleanup ═══${NC}"
remote "sudo rm -rf '${REMOTE_DIR}' /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums"
echo -e "${GREEN}✓ Temporary files removed${NC}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Summary ═══${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}Success: ${SUCCESS_COUNT}${NC}  ${YELLOW}Warnings: ${WARN_COUNT}${NC}  ${RED}Errors: ${ERROR_COUNT}${NC}"

# [M-8] Print rollback command hint
if [[ -n "${LAST_BACKUP_NAME:-}" ]]; then
    echo -e "\n  ${CYAN}To rollback:${NC}"
    echo -e "  ./scripts/rollback-fork.sh --host ${HOST} --user ${SSH_USER} --users ${USERS} --backup-path /var/lib/zeroclaw-backups/${LAST_BACKUP_NAME}"
fi
echo ""
