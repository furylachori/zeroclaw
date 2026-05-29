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

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

TARBALL_URL="https://github.com/furylachori/zeroclaw/releases/download/${TAG}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz"
REMOTE_DIR="/tmp/zeroclaw-upgrade"

# ── Helper: run command on VPS ───────────────────────────────────────────────
remote() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${HOST}" "$@"
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

    # Verify user exists on the VPS
    if ! remote "id '$user' &>/dev/null"; then
        echo -e "  ${RED}❌ User '${user}' does not exist on VPS${NC}"
        RESULTS+=("${user}: ❌ error (user not found)")
        ((ERROR_COUNT++)) || true
        continue
    fi

    USER_HOME="$(remote "eval echo ~$user")"

    # ── Copy binary ──
    echo -e "  ${YELLOW}▸ Installing binary...${NC}"
    remote "mkdir -p '${USER_HOME}/.cargo/bin' && cp '${REMOTE_DIR}/zeroclaw' '${USER_HOME}/.cargo/bin/zeroclaw' && chmod 755 '${USER_HOME}/.cargo/bin/zeroclaw' && chown '${user}:' '${USER_HOME}/.cargo/bin/zeroclaw'"
    echo -e "  ${GREEN}✓ Binary installed${NC}"

    # ── Copy web dist ──
    echo -e "  ${YELLOW}▸ Installing web dist...${NC}"
    remote "mkdir -p '${USER_HOME}/.local/share/zeroclaw/web' && rm -rf '${USER_HOME}/.local/share/zeroclaw/web/dist' && cp -r '${REMOTE_DIR}/web/dist' '${USER_HOME}/.local/share/zeroclaw/web/dist' && chown -R '${user}:' '${USER_HOME}/.local/share/zeroclaw/web'"
    echo -e "  ${GREEN}✓ Web dist installed${NC}"

    # ── Config update ──
    CONFIG_PATH="${USER_HOME}/.zeroclaw/config.toml"
    CONFIG_EXISTS="$(remote "test -f '${CONFIG_PATH}' && echo yes || echo no")"

    if [[ "$CONFIG_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ config.toml not found — skipping config update${NC}"
        STATUS="warn"
        ((WARN_COUNT++)) || true
    else
        HAS_KEY="$(remote "grep -c 'process_audio_without_transcription' '${CONFIG_PATH}' || true")"
        if [[ "$HAS_KEY" -gt 0 ]]; then
            echo -e "  ${GREEN}✓ process_audio_without_transcription already present${NC}"
        else
            echo -e "  ${YELLOW}▸ Appending [channels.telegram.default] block...${NC}"
            remote "cat >> '${CONFIG_PATH}' <<'TOML'

[channels.telegram.default]
process_audio_without_transcription = true
TOML"
            remote "chown '${user}:' '${CONFIG_PATH}'"
            echo -e "  ${GREEN}✓ Config updated${NC}"
        fi
    fi

    # ── Restart systemd service ──
    SVC_EXISTS="$(remote "sudo -u '$user' XDG_RUNTIME_DIR=/run/user/\$(id -u '$user') systemctl --user status zeroclaw &>/dev/null && echo yes || echo no")"
    if [[ "$SVC_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
        if [[ "$STATUS" == "ok" ]]; then STATUS="warn"; fi
        ((WARN_COUNT++)) || true
    else
        echo -e "  ${YELLOW}▸ Restarting zeroclaw service...${NC}"
        remote "sudo -u '$user' XDG_RUNTIME_DIR=/run/user/\$(id -u '$user') systemctl --user restart zeroclaw"
        echo -e "  ${GREEN}✓ Service restarted${NC}"
    fi

    if [[ "$STATUS" == "ok" ]]; then
        echo -e "  ${GREEN}✅ ${user}: upgrade complete${NC}"
        RESULTS+=("${user}: ✅ success")
        ((SUCCESS_COUNT++)) || true
    else
        echo -e "  ${YELLOW}⚠️  ${user}: upgrade complete with warnings${NC}"
        RESULTS+=("${user}: ⚠️  warning (check details above)")
    fi
done

# ── Phase 3: Cleanup ────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Phase 3: Cleanup ═══${NC}"
remote "rm -rf '${REMOTE_DIR}' /tmp/zeroclaw-upgrade.tar.gz"
echo -e "${GREEN}✓ Temporary files removed${NC}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Summary ═══${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}Success: ${SUCCESS_COUNT}${NC}  ${YELLOW}Warnings: ${WARN_COUNT}${NC}  ${RED}Errors: ${ERROR_COUNT}${NC}"
echo ""
