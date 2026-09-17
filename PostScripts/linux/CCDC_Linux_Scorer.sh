#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Target Scorer
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Scores the current state of the Linux target across 3 categories:
#   1. Scored Services   (100) - blue team: keep these UP
#   2. Persistence       (100) - red team:  how much survived
#   3. Rogue Users       (100) - red team:  backdoor accounts alive
# Total: /300
#
# Run: sudo bash CCDC_Linux_Scorer.sh
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# -- Root check ---------------------------------------------------------------
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: must run as root (sudo bash $0)"
    exit 1
fi

# -- ANSI colors --------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
RESET='\033[0m'

# -- Score accumulators -------------------------------------------------------
S1=0   # Scored Services
S2=0   # Persistence Survival
S3=0   # Rogue Users

# -- Helpers ------------------------------------------------------------------
section() {
    echo -e "\n${CYAN}==[ $1 ]==${RESET}\n"
}

subtotal() {
    echo -e "\n${YELLOW}  Subtotal: $1 / $2${RESET}"
}

# check <category> <points> <label> <1|0>
check() {
    local cat="$1" pts="$2" label="$3" pass="$4"
    if [[ "$pass" == "1" ]]; then
        printf "${GREEN}[PASS +%2d] %s${RESET}\n" "$pts" "$label"
        case "$cat" in
            S1) S1=$((S1 + pts)) ;;
            S2) S2=$((S2 + pts)) ;;
            S3) S3=$((S3 + pts)) ;;
        esac
    else
        printf "${RED}[FAIL  +0] %s${RESET}\n" "$label"
    fi
}

# svc_active <unit> -- returns 1 if active, 0 otherwise
svc_active() {
    systemctl is-active --quiet "$1" 2>/dev/null && echo 1 || echo 0
}

# port_listening <port> -- returns 1 if something is listening on that port
port_listening() {
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$" && echo 1 || echo 0
}

# http_ok <url> -- returns 1 if HTTP response is 2xx or 3xx
http_ok() {
    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    [[ "$code" =~ ^[23] ]] && echo 1 || echo 0
}

# file_exists <path> -- returns 1 if file/dir exists
file_exists() {
    [[ -e "$1" ]] && echo 1 || echo 0
}

# file_contains <path> <string> -- returns 1 if file contains the string
file_contains() {
    grep -qF "$2" "$1" 2>/dev/null && echo 1 || echo 0
}

# immutable <path> -- returns 1 if the file has the 'i' (immutable) attribute
immutable() {
    lsattr "$1" 2>/dev/null | awk 'NR==1{print $1}' | grep -qF 'i' && echo 1 || echo 0
}

# user_exists <username>
user_exists() {
    getent passwd "$1" &>/dev/null && echo 1 || echo 0
}

# in_sudo_group <username> -- checks for 'sudo' or 'wheel' group
in_sudo_group() {
    (id -nG "$1" 2>/dev/null | grep -qE '\b(sudo|wheel)\b') && echo 1 || echo 0
}

# =============================================================================
# BANNER
# =============================================================================
echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC Blue Team Training - Linux Target Scorer${RESET}"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""

# =============================================================================
# CATEGORY 1 - SCORED SERVICES (100 pts)
# Services blue team must keep running. Higher score = blue team winning.
# =============================================================================
section "CATEGORY 1 - SCORED SERVICES (100 pts)"

# apache2 service active - 15 pts
check S1 15 "apache2 service active" "$(svc_active apache2)"

# HTTP 200 on localhost - 15 pts
check S1 15 "HTTP GET http://localhost returns 2xx/3xx" "$(http_ok http://localhost)"

# postfix service active - 15 pts
check S1 15 "postfix service active" "$(svc_active postfix)"

# SMTP port 25 listening - 10 pts
check S1 10 "SMTP port 25 listening" "$(port_listening 25)"

# dovecot service active - 15 pts
check S1 15 "dovecot service active" "$(svc_active dovecot)"

# IMAP port 143 listening - 10 pts
check S1 10 "IMAP port 143 listening" "$(port_listening 143)"

# POP3 port 110 listening - 5 pts
check S1 5 "POP3 port 110 listening" "$(port_listening 110)"

# Splunk service active (unit may be Splunkd or splunk) - 10 pts
SPLUNK_ACTIVE=0
if systemctl is-active --quiet Splunkd 2>/dev/null || systemctl is-active --quiet splunk 2>/dev/null; then
    SPLUNK_ACTIVE=1
fi
check S1 10 "Splunk service (Splunkd/splunk) active" "$SPLUNK_ACTIVE"

# Splunk port 8000 responding - 5 pts
check S1 5 "Splunk port 8000 responding (http://localhost:8000)" "$(http_ok http://localhost:8000)"

subtotal "$S1" 100

# =============================================================================
# CATEGORY 2 - PERSISTENCE SURVIVAL (100 pts)
# Planted artifacts. Higher score = red team persistence survived.
# =============================================================================
section "CATEGORY 2 - PERSISTENCE SURVIVAL (100 pts)"

# -- Cron jobs ----------------------------------------------------------------
# /etc/cron.d/grub-service (every 5 min service killer) - 10 pts
check S2 10 "/etc/cron.d/grub-service present (5-min service killer)" \
    "$(file_exists /etc/cron.d/grub-service)"

# /etc/cron.d/sillyevilcronjob (every 3 min service killer) - 10 pts
check S2 10 "/etc/cron.d/sillyevilcronjob present (3-min service killer)" \
    "$(file_exists /etc/cron.d/sillyevilcronjob)"

# -- Persistence location 1: rc.local ----------------------------------------
# /etc/rc.local contains sysinit-helper call - 10 pts
check S2 10 '/etc/rc.local contains "sysinit-helper" launcher' \
    "$(file_contains /etc/rc.local 'sysinit-helper')"

# /usr/local/lib/.sysinit-helper payload - 3 pts
check S2 3 "/usr/local/lib/.sysinit-helper payload present" \
    "$(file_exists /usr/local/lib/.sysinit-helper)"

# -- Persistence location 2: profile.d ----------------------------------------
# /etc/profile.d/99-sysenv-init.sh - 8 pts
check S2 8 "/etc/profile.d/99-sysenv-init.sh present" \
    "$(file_exists /etc/profile.d/99-sysenv-init.sh)"

# /usr/local/lib/.sysenv-init payload - 3 pts
check S2 3 "/usr/local/lib/.sysenv-init payload present" \
    "$(file_exists /usr/local/lib/.sysenv-init)"

# -- Persistence location 3: systemd service ----------------------------------
# /etc/systemd/system/sys-khelper-init.service unit file - 8 pts
check S2 8 "/etc/systemd/system/sys-khelper-init.service present" \
    "$(file_exists /etc/systemd/system/sys-khelper-init.service)"

# sys-khelper-init.service enabled - 4 pts
KHELPER_ENABLED=0
systemctl is-enabled --quiet sys-khelper-init.service 2>/dev/null && KHELPER_ENABLED=1
check S2 4 "sys-khelper-init.service enabled" "$KHELPER_ENABLED"

# /usr/local/lib/.khelper-init payload - 3 pts
check S2 3 "/usr/local/lib/.khelper-init payload present" \
    "$(file_exists /usr/local/lib/.khelper-init)"

# -- Persistence location 4: cron.d/@reboot ----------------------------------
# /etc/cron.d/syslogd-helper - 5 pts
check S2 5 "/etc/cron.d/syslogd-helper present (@reboot persistence)" \
    "$(file_exists /etc/cron.d/syslogd-helper)"

# /usr/local/lib/.syslogd-helper payload - 3 pts
check S2 3 "/usr/local/lib/.syslogd-helper payload present" \
    "$(file_exists /usr/local/lib/.syslogd-helper)"

# -- Persistence location 5: .bashrc -----------------------------------------
# /root/.bashrc contains __sysnet_diag_hook__ marker - 10 pts
check S2 10 '/root/.bashrc contains "__sysnet_diag_hook__" marker' \
    "$(file_contains /root/.bashrc '__sysnet_diag_hook__')"

# /usr/local/lib/.sysnet-diag payload - 3 pts
check S2 3 "/usr/local/lib/.sysnet-diag payload present" \
    "$(file_exists /usr/local/lib/.sysnet-diag)"

# -- Rogue web shell service --------------------------------------------------
# web-php.service active - 10 pts
check S2 10 "web-php service active (rogue PHP shell)" "$(svc_active web-php)"

# Port 8888 listening - 5 pts
check S2 5 "Port 8888 listening (rogue PHP shell)" "$(port_listening 8888)"

# /opt/web-php/www/index.php present - 5 pts
check S2 5 "/opt/web-php/www/index.php present" \
    "$(file_exists /opt/web-php/www/index.php)"

subtotal "$S2" 100

# =============================================================================
# CATEGORY 3 - ROGUE USERS & LOCKOUT (100 pts)
# Backdoor accounts and immutable file lockout. Higher = red team winning.
# =============================================================================
section "CATEGORY 3 - ROGUE USERS & LOCKOUT (100 pts)"

for USERNAME in ubuntu johnredteam "systemd-bus-proxy"; do
    # User exists - 13 pts
    check S3 13 "User \"$USERNAME\" exists" "$(user_exists "$USERNAME")"

    # In sudo/wheel group - 8 pts
    check S3 8 "\"$USERNAME\" in sudo group" "$(in_sudo_group "$USERNAME")"

    # Sudoers drop-in present - 5 pts
    check S3 5 "/etc/sudoers.d/99-${USERNAME} present" \
        "$(file_exists "/etc/sudoers.d/99-${USERNAME}")"

    # Sudoers file has immutable flag - 3 pts
    check S3 3 "/etc/sudoers.d/99-${USERNAME} has immutable (chattr +i) flag" \
        "$(immutable "/etc/sudoers.d/99-${USERNAME}")"
done

# /etc/passwd immutable - 5 pts
check S3 5 "/etc/passwd has immutable (chattr +i) flag" "$(immutable /etc/passwd)"

# /etc/shadow immutable - 5 pts
check S3 5 "/etc/shadow has immutable (chattr +i) flag" "$(immutable /etc/shadow)"

# Any of the three sudoers.d files is immutable (combined check) - 3 pts
ANY_SUDOERS_IMM=0
for u in ubuntu johnredteam "systemd-bus-proxy"; do
    if [[ "$(immutable "/etc/sudoers.d/99-${u}")" == "1" ]]; then
        ANY_SUDOERS_IMM=1
        break
    fi
done
check S3 3 "At least one /etc/sudoers.d drop-in still immutable" "$ANY_SUDOERS_IMM"

subtotal "$S3" 100

# =============================================================================
# SUMMARY TABLE
# =============================================================================
TOTAL=$((S1 + S2 + S3))

score_color() {
    local s=$1
    if [[ $s -ge 70 ]]; then echo "$GREEN"
    elif [[ $s -ge 40 ]]; then echo "$YELLOW"
    else echo "$RED"
    fi
}

echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC LINUX SCORE SUMMARY${RESET}"
echo -e "${CYAN}========================================================${RESET}"
printf "${WHITE}  %-28s${RESET} $(score_color $S1)%3d / 100${RESET}\n" \
    "Scored Services [blue team]:" "$S1"
printf "${WHITE}  %-28s${RESET} $(score_color $S2)%3d / 100${RESET}\n" \
    "Persistence Survival [red]:" "$S2"
printf "${WHITE}  %-28s${RESET} $(score_color $S3)%3d / 100${RESET}\n" \
    "Rogue Users [red team]:" "$S3"
echo -e "${CYAN}--------------------------------------------------------${RESET}"
printf "${WHITE}  %-28s %3d / 300${RESET}\n" "TOTAL:" "$TOTAL"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""
