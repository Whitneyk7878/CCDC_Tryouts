#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Target Scorer
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Grades the DEFENDER (blue team) across 3 categories. Higher = better defense.
#   1. Scored Services   (100) - scored services still running
#   2. Persistence Removed (100) - planted persistence found and cleaned
#   3. Rogue Users Removed (100) - backdoor accounts found and deleted
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
S1=0
S2=0
S3=0

# -- Helpers ------------------------------------------------------------------
section() {
    echo -e "\n${CYAN}==[ $1 ]==${RESET}\n"
}

subtotal() {
    echo -e "\n${YELLOW}  Subtotal: $1 / $2${RESET}"
}

# check <category> <points> <label> <1=pass|0=fail>
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

svc_active() {
    systemctl is-active --quiet "$1" 2>/dev/null && echo 1 || echo 0
}

port_listening() {
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$" && echo 1 || echo 0
}

http_ok() {
    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    [[ "$code" =~ ^[23] ]] && echo 1 || echo 0
}

file_gone()     { [[ ! -e "$1" ]] && echo 1 || echo 0; }
file_exists()   { [[ -e  "$1" ]] && echo 1 || echo 0; }

# file_no_str <path> <string> -- returns 1 if file does NOT contain the string
file_no_str() {
    grep -qF "$2" "$1" 2>/dev/null && echo 0 || echo 1
}

# immutable <path> -- returns 1 if 'i' flag IS set (bad for defender)
immutable() {
    lsattr "$1" 2>/dev/null | awk 'NR==1{print $1}' | grep -qF 'i' && echo 1 || echo 0
}

# not_immutable <path> -- returns 1 if 'i' flag is CLEARED (defender wins)
not_immutable() {
    lsattr "$1" 2>/dev/null | awk 'NR==1{print $1}' | grep -qF 'i' && echo 0 || echo 1
}

user_gone() {
    getent passwd "$1" &>/dev/null && echo 0 || echo 1
}

not_in_sudo() {
    id -nG "$1" 2>/dev/null | grep -qE '\b(sudo|wheel)\b' && echo 0 || echo 1
}

# =============================================================================
# BANNER
# =============================================================================
echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC Blue Team Training - Linux Defender Scorer${RESET}"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""

# =============================================================================
# CATEGORY 1 - SCORED SERVICES (100 pts)
# Blue team gets points for keeping legitimate services UP.
# =============================================================================
section "CATEGORY 1 - SCORED SERVICES (100 pts)"

check S1 15 "apache2 service active" "$(svc_active apache2)"
check S1 15 "HTTP GET http://localhost returns 2xx/3xx" "$(http_ok http://localhost)"
check S1 15 "postfix service active" "$(svc_active postfix)"
check S1 10 "SMTP port 25 listening" "$(port_listening 25)"
check S1 15 "dovecot service active" "$(svc_active dovecot)"
check S1 10 "IMAP port 143 listening" "$(port_listening 143)"
check S1  5 "POP3 port 110 listening" "$(port_listening 110)"

SPLUNK_ACTIVE=0
if systemctl is-active --quiet Splunkd 2>/dev/null || \
   systemctl is-active --quiet splunk 2>/dev/null; then
    SPLUNK_ACTIVE=1
fi
check S1 10 "Splunk service (Splunkd/splunk) active" "$SPLUNK_ACTIVE"
check S1  5 "Splunk port 8000 responding" "$(http_ok http://localhost:8000)"

subtotal "$S1" 100

# =============================================================================
# CATEGORY 2 - PERSISTENCE REMOVED (100 pts)
# Blue team gets points for each planted artifact that has been CLEANED UP.
# =============================================================================
section "CATEGORY 2 - PERSISTENCE REMOVED (100 pts)"

# -- Cron jobs ----------------------------------------------------------------
check S2 10 "/etc/cron.d/grub-service removed (5-min service killer)" \
    "$(file_gone /etc/cron.d/grub-service)"

check S2 10 "/etc/cron.d/sillyevilcronjob removed (3-min service killer)" \
    "$(file_gone /etc/cron.d/sillyevilcronjob)"

# -- Persistence location 1: rc.local ----------------------------------------
check S2 10 '/etc/rc.local no longer contains "sysinit-helper"' \
    "$(file_no_str /etc/rc.local 'sysinit-helper')"

check S2 3 "/usr/local/lib/.sysinit-helper payload removed" \
    "$(file_gone /usr/local/lib/.sysinit-helper)"

# -- Persistence location 2: profile.d ----------------------------------------
check S2 8 "/etc/profile.d/99-sysenv-init.sh removed" \
    "$(file_gone /etc/profile.d/99-sysenv-init.sh)"

check S2 3 "/usr/local/lib/.sysenv-init payload removed" \
    "$(file_gone /usr/local/lib/.sysenv-init)"

# -- Persistence location 3: systemd service ----------------------------------
check S2 8 "/etc/systemd/system/sys-khelper-init.service removed" \
    "$(file_gone /etc/systemd/system/sys-khelper-init.service)"

KHELPER_DISABLED=1
systemctl is-enabled --quiet sys-khelper-init.service 2>/dev/null && KHELPER_DISABLED=0
check S2 4 "sys-khelper-init.service disabled/removed" "$KHELPER_DISABLED"

check S2 3 "/usr/local/lib/.khelper-init payload removed" \
    "$(file_gone /usr/local/lib/.khelper-init)"

# -- Persistence location 4: cron.d syslogd-helper ---------------------------
check S2 5 "/etc/cron.d/syslogd-helper removed (@reboot persistence)" \
    "$(file_gone /etc/cron.d/syslogd-helper)"

check S2 3 "/usr/local/lib/.syslogd-helper payload removed" \
    "$(file_gone /usr/local/lib/.syslogd-helper)"

# -- Persistence location 5: .bashrc -----------------------------------------
check S2 10 '/root/.bashrc no longer contains "__sysnet_diag_hook__"' \
    "$(file_no_str /root/.bashrc '__sysnet_diag_hook__')"

check S2 3 "/usr/local/lib/.sysnet-diag payload removed" \
    "$(file_gone /usr/local/lib/.sysnet-diag)"

# -- Rogue web shell service --------------------------------------------------
WEB_PHP_GONE=0
systemctl is-active --quiet web-php 2>/dev/null || WEB_PHP_GONE=1
check S2 10 "web-php service stopped and removed" "$WEB_PHP_GONE"

check S2 5 "Port 8888 no longer listening" \
    "$(port_listening 8888 | sed 's/1/X/;s/0/1/;s/X/0/')"

check S2 5 "/opt/web-php/www/index.php removed" \
    "$(file_gone /opt/web-php/www/index.php)"

subtotal "$S2" 100

# =============================================================================
# CATEGORY 3 - ROGUE USERS REMOVED (100 pts)
# Blue team gets points for each backdoor account that has been CLEANED UP.
# Includes immutable flag removal on /etc/passwd, /etc/shadow, sudoers.d files.
# =============================================================================
section "CATEGORY 3 - ROGUE USERS REMOVED (100 pts)"

for USERNAME in ubuntu johnredteam "systemd-bus-proxy"; do
    # User gone - 13 pts
    check S3 13 "User \"$USERNAME\" removed" "$(user_gone "$USERNAME")"

    # No longer in sudo group - 8 pts
    # (if user is gone this still passes; check via getent to avoid id errors)
    if getent passwd "$USERNAME" &>/dev/null; then
        check S3 8 "\"$USERNAME\" removed from sudo group" "$(not_in_sudo "$USERNAME")"
    else
        printf "${GREEN}[PASS +%2d] \"%s\" removed from sudo group (user gone)${RESET}\n" 8 "$USERNAME"
        S3=$((S3 + 8))
    fi

    # Sudoers drop-in gone - 5 pts
    check S3 5 "/etc/sudoers.d/99-${USERNAME} removed" \
        "$(file_gone "/etc/sudoers.d/99-${USERNAME}")"

    # Sudoers immutable flag cleared - 3 pts
    SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
    if [[ ! -e "$SUDOERS_FILE" ]]; then
        printf "${GREEN}[PASS +%2d] /etc/sudoers.d/99-%s immutable flag cleared (file gone)${RESET}\n" \
            3 "$USERNAME"
        S3=$((S3 + 3))
    else
        check S3 3 "/etc/sudoers.d/99-${USERNAME} immutable (chattr +i) flag cleared" \
            "$(not_immutable "$SUDOERS_FILE")"
    fi
done

# /etc/passwd immutable flag cleared - 5 pts
check S3 5 "/etc/passwd immutable (chattr +i) flag cleared" "$(not_immutable /etc/passwd)"

# /etc/shadow immutable flag cleared - 5 pts
check S3 5 "/etc/shadow immutable (chattr +i) flag cleared" "$(not_immutable /etc/shadow)"

# All three sudoers.d files gone (combined bonus) - 3 pts
ALL_GONE=1
for u in ubuntu johnredteam "systemd-bus-proxy"; do
    [[ -e "/etc/sudoers.d/99-${u}" ]] && ALL_GONE=0 && break
done
check S3 3 "All /etc/sudoers.d drop-ins removed (all three gone)" "$ALL_GONE"

subtotal "$S3" 100

# =============================================================================
# SUMMARY TABLE
# =============================================================================
TOTAL=$((S1 + S2 + S3))

score_color() {
    local s=$1
    if [[ $s -ge 70 ]]; then echo -e "$GREEN"
    elif [[ $s -ge 40 ]]; then echo -e "$YELLOW"
    else echo -e "$RED"
    fi
}

echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC LINUX DEFENDER SCORE${RESET}"
echo -e "${CYAN}========================================================${RESET}"
printf "${WHITE}  %-26s${RESET} $(score_color $S1)%3d / 100${RESET}\n" \
    "Scored Services:" "$S1"
printf "${WHITE}  %-26s${RESET} $(score_color $S2)%3d / 100${RESET}\n" \
    "Persistence Removed:" "$S2"
printf "${WHITE}  %-26s${RESET} $(score_color $S3)%3d / 100${RESET}\n" \
    "Rogue Users Removed:" "$S3"
echo -e "${CYAN}--------------------------------------------------------${RESET}"
printf "${WHITE}  %-26s %3d / 300${RESET}\n" "TOTAL:" "$TOTAL"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""
