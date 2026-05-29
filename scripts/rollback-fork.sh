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
BACKUP_PATH=""
SUCCESS_COUNT=0
ERROR_COUNT=0
declare -a RESULTS=()

# ── Escape single quotes for safe embedding in remote shell commands ─────────
sq() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  rollback-fork.sh --host <vps-host> --user <ssh-user> --users <user1,user2,...> --backup-path <path>

${BOLD}Required:${NC}
  --host <host>          VPS hostname or IP address
  --user <user>          SSH user for the VPS
  --users <list>         Comma-separated list of zeroclaw user accounts on the VPS
  --backup-path <path>   Full path on the VPS to the old zeroclaw binary

${BOLD}Optional:${NC}
  --key <path>           Path to SSH private key (uses default if omitted)
  --help                 Show this help message

${BOLD}Example:${NC}
  rollback-fork.sh --host vps.example.com --user root --users cosita,espinas,fury \\
    --backup-path /root/zeroclaw-backups/zeroclaw-v0.2.9
EOF
    exit 0
}

SSH_KEY=""

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2";         shift 2 ;;
        --user)        SSH_USER="$2";     shift 2 ;;
        --users)       USERS="$2";        shift 2 ;;
        --backup-path) BACKUP_PATH="$2";  shift 2 ;;
        --key)         SSH_KEY="$2";      shift 2 ;;
        --help)        usage ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            exit 1
            ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$HOST" || -z "$SSH_USER" || -z "$USERS" || -z "$BACKUP_PATH" ]]; then
    echo -e "${RED}Error: --host, --user, --users, and --backup-path are required.${NC}" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    # shellcheck disable=SC2086
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "rm -rf /tmp/zeroclaw-upgrade" 2>/dev/null || true
}
trap cleanup EXIT

# ── Helper: run command on VPS ───────────────────────────────────────────────
remote() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$@"
}

# ── Verify connection and backup ────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Rollback ═══${NC}"
echo -e "Host: ${BOLD}${HOST}${NC}  Backup: ${BOLD}${BACKUP_PATH}${NC}"

echo -e "${YELLOW}▸ Testing SSH connection...${NC}"
if ! remote "true"; then
    echo -e "${RED}❌ SSH connection to ${SSH_USER}@${HOST} failed.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ SSH connection OK${NC}"

echo -e "${YELLOW}▸ Verifying backup binary exists...${NC}"
if ! remote "test -x '$(sq "$BACKUP_PATH")'"; then
    echo -e "${RED}❌ Backup binary not found or not executable at '${BACKUP_PATH}'${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Backup binary found${NC}"

# ── Roll back each user ─────────────────────────────────────────────────────
IFS=',' read -ra USER_LIST <<< "$USERS"

for user in "${USER_LIST[@]}"; do
    user="$(echo "$user" | xargs)"
    echo -e "\n${BOLD}── User: ${user} ──${NC}"

    # Validate username format to prevent command injection
    if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo -e "  ${RED}❌ Invalid username format: '${user}'${NC}"
        RESULTS+=("${user}: ❌ error (invalid username)")
        ((ERROR_COUNT++)) || true
        continue
    fi

    if ! remote "id '$(sq "$user")' &>/dev/null"; then
        echo -e "  ${RED}❌ User '${user}' does not exist on VPS${NC}"
        RESULTS+=("${user}: ❌ error (user not found)")
        ((ERROR_COUNT++)) || true
        continue
    fi

    USER_HOME="$(remote "getent passwd '$(sq "$user")' | cut -d: -f6")"

    # ── Restore binary ──
    echo -e "  ${YELLOW}▸ Restoring binary...${NC}"
    remote "mkdir -p '$(sq "$USER_HOME")/.cargo/bin' && cp '$(sq "$BACKUP_PATH")' '$(sq "$USER_HOME")/.cargo/bin/zeroclaw' && chmod 755 '$(sq "$USER_HOME")/.cargo/bin/zeroclaw' && chown '$(sq "$user"):' '$(sq "$USER_HOME")/.cargo/bin/zeroclaw'"
    echo -e "  ${GREEN}✓ Binary restored${NC}"

    # ── Restart systemd service ──
    SVC_EXISTS="$(remote "sudo -u '$(sq "$user")' XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user status zeroclaw &>/dev/null && echo yes || echo no")"
    if [[ "$SVC_EXISTS" == "no" ]]; then
        echo -e "  ${YELLOW}⚠ systemd user service not found — skipping restart${NC}"
        RESULTS+=("${user}: ⚠️  binary restored, service not restarted")
    else
        echo -e "  ${YELLOW}▸ Restarting zeroclaw service...${NC}"
        remote "sudo -u '$(sq "$user")' XDG_RUNTIME_DIR=/run/user/\$(id -u '$(sq "$user")') systemctl --user restart zeroclaw"
        echo -e "  ${GREEN}✓ Service restarted${NC}"
        echo -e "  ${GREEN}✅ ${user}: rollback complete${NC}"
        RESULTS+=("${user}: ✅ success")
        ((SUCCESS_COUNT++)) || true
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}═══ Summary ═══${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}Success: ${SUCCESS_COUNT}${NC}  ${RED}Errors: ${ERROR_COUNT}${NC}"
echo ""
