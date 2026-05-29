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

SSH_OPTS=(-o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

TARBALL_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz"
SHA256_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/SHA256SUMS"
REMOTE_DIR="/tmp/zeroclaw-upgrade"

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    # shellcheck disable=SC2086
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "rm -rf '${REMOTE_DIR}' /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums" 2>/dev/null || true
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

echo -e "${YELLOW}▸ Downloading release tarball...${NC}"
if ! remote "curl -fsSL -o /tmp/zeroclaw-upgrade.tar.gz '${TARBALL_URL}'"; then
    echo -e "${RED}❌ Download failed. Check that tag '${TAG}' exists.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Download complete${NC}"

# ── Phase 1b: Checksum verification ─────────────────────────────────────────
echo -e "${YELLOW}▸ Downloading SHA256SUMS...${NC}"
if remote "curl -fsSL -o /tmp/zeroclaw-sha256sums '${SHA256_URL}'"; then
    if remote "cd /tmp && grep 'zeroclaw-x86_64-unknown-linux-gnu.tar.gz' zeroclaw-sha256sums | sha256sum -c -"; then
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

    # ── Backup existing binary ──
    echo -e "  ${YELLOW}▸ Backing up existing binary...${NC}"
    BACKUP_NAME="zeroclaw-$(date +%Y%m%d%H%M%S)"
    remote "mkdir -p /tmp/zeroclaw-backups && cp '$(sq "$USER_HOME")/.cargo/bin/zeroclaw' '/tmp/zeroclaw-backups/${BACKUP_NAME}' 2>/dev/null || echo 'no existing binary to back up'"
    echo -e "  ${GREEN}✓ Backup saved to /tmp/zeroclaw-backups/${BACKUP_NAME}${NC}"

    # ── Copy binary ──
    echo -e "  ${YELLOW}▸ Installing binary...${NC}"
    remote "mkdir -p '$(sq "$USER_HOME")/.cargo/bin' && cp '${REMOTE_DIR}/zeroclaw' '$(sq "$USER_HOME")/.cargo/bin/zeroclaw' && chmod 755 '$(sq "$USER_HOME")/.cargo/bin/zeroclaw' && chown '$(sq "$user"):' '$(sq "$USER_HOME")/.cargo/bin/zeroclaw'"
    echo -e "  ${GREEN}✓ Binary installed${NC}"

    # ── Copy web dist ──
    echo -e "  ${YELLOW}▸ Installing web dist...${NC}"
    remote "mkdir -p '$(sq "$USER_HOME")/.local/share/zeroclaw/web' && rm -rf '$(sq "$USER_HOME")/.local/share/zeroclaw/web/dist' && cp -r '${REMOTE_DIR}/web/dist' '$(sq "$USER_HOME")/.local/share/zeroclaw/web/dist' && chown -R '$(sq "$user"):' '$(sq "$USER_HOME")/.local/share/zeroclaw/web'"
    echo -e "  ${GREEN}✓ Web dist installed${NC}"

    # ── Config update ──
    CONFIG_PATH="${USER_HOME}/.zeroclaw/config.toml"
    CONFIG_EXISTS="$(remote "test -f '$(sq "$CONFIG_PATH")' && echo yes || echo no")"

    if [[ "$CONFIG_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ config.toml not found — skipping config update${NC}"
        STATUS="warn"
        ((WARN_COUNT++)) || true
    else
        HAS_KEY="$(remote "grep -c 'process_audio_without_transcription' '$(sq "$CONFIG_PATH")' 2>/dev/null || echo 0")"
        if [[ "$HAS_KEY" -gt 0 ]]; then
            echo -e "  ${GREEN}✓ process_audio_without_transcription already present${NC}"
        else
            echo -e "  ${YELLOW}▸ Adding process_audio_without_transcription...${NC}"
            # Back up config first
            remote "cp '$(sq "$CONFIG_PATH")' '$(sq "$CONFIG_PATH").bak.$(date +%s)'"

            HAS_SECTION="$(remote "grep -c '^\[channels\.telegram\.default\]' '$(sq "$CONFIG_PATH")' 2>/dev/null || echo 0")"
            if [[ "$HAS_SECTION" -gt 0 ]]; then
                # Insert key after existing section header
                remote "sed -i '/^\[channels\.telegram\.default\]/a process_audio_without_transcription = true' '$(sq "$CONFIG_PATH")'"
            else
                # Append new section
                remote "cat >> '$(sq "$CONFIG_PATH")' <<'TOML'

[channels.telegram.default]
process_audio_without_transcription = true
TOML"
            fi
            remote "chown '$(sq "$user"):' '$(sq "$CONFIG_PATH")'"
            echo -e "  ${GREEN}✓ Config updated${NC}"
        fi
    fi

    # ── Restart systemd service ──
    SVC_EXISTS="$(remote "sudo -u '$(sq "$user")' XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user status zeroclaw &>/dev/null && echo yes || echo no")"
    if [[ "$SVC_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
        if [[ "$STATUS" == "ok" ]]; then STATUS="warn"; fi
        ((WARN_COUNT++)) || true
    else
        echo -e "  ${YELLOW}▸ Restarting zeroclaw service...${NC}"
        remote "sudo -u '$(sq "$user")' XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user restart zeroclaw"
        echo -e "  ${GREEN}✓ Service restarted${NC}"
    fi

    if [[ "$STATUS" == "ok" ]]; then
        echo -e "  ${GREEN}✅ ${user}: upgrade complete${NC}"
        RESULTS+=("${user}: ✅ success (backup: /tmp/zeroclaw-backups/${BACKUP_NAME})")
        ((SUCCESS_COUNT++)) || true
    else
        echo -e "  ${YELLOW}⚠️  ${user}: upgrade complete with warnings${NC}"
        RESULTS+=("${user}: ⚠️  warning (check details above)")
    fi
done

# ── Phase 3: Cleanup ────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 3: Cleanup ═══${NC}"
remote "rm -rf '${REMOTE_DIR}' /tmp/zeroclaw-upgrade.tar.gz /tmp/zeroclaw-sha256sums"
echo -e "${GREEN}✓ Temporary files removed${NC}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Summary ═══${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}Success: ${SUCCESS_COUNT}${NC}  ${YELLOW}Warnings: ${WARN_COUNT}${NC}  ${RED}Errors: ${ERROR_COUNT}${NC}"
echo ""
