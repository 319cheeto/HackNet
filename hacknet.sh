#!/bin/bash
# ============================================================================
# HackNet v5.0 — Unified Installer / Uninstaller / Recovery
# ============================================================================
# A safe, isolated network namespace for cybersecurity lab work.
#
# Usage:  sudo ./hacknet.sh              (interactive menu)
#         sudo ./hacknet.sh install       (install HackNet)
#         sudo ./hacknet.sh uninstall     (remove HackNet)
#         sudo ./hacknet.sh recover       (emergency network recovery)
# ============================================================================

set -e

# ── Global constants ────────────────────────────────────────────────────────
NS="HackNet"
STATIC_IP="192.168.25.25"
LOG_FILE="$HOME/.hacknet_labs.log"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="$HOME/.hacknet_config"

# ── Helpers ─────────────────────────────────────────────────────────────────

log_msg()  { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# Find a working terminal emulator
find_terminal() {
    for t in x-terminal-emulator qterminal gnome-terminal xfce4-terminal konsole lxterminal xterm; do
        command -v "$t" &>/dev/null && echo "$t" && return
    done
    echo ""
}

# Find a working DHCP client
run_dhcp() {
    local iface="$1" timeout="${2:-15}" ns="${3:-}"
    local prefix=""
    [ -n "$ns" ] && prefix="ip netns exec $ns"
    if command -v dhcpcd &>/dev/null; then
        sudo $prefix dhcpcd "$iface" -t "$timeout" 2>/dev/null || true
    elif command -v dhclient &>/dev/null; then
        sudo $prefix dhclient -timeout "$timeout" "$iface" 2>/dev/null || true
    fi
}

release_dhcp() {
    local iface="$1" ns="${2:-}"
    local prefix=""
    [ -n "$ns" ] && prefix="ip netns exec $ns"
    sudo $prefix dhcpcd -k "$iface" 2>/dev/null || true
    sudo $prefix dhclient -r "$iface" 2>/dev/null || true
    sudo $prefix pkill -9 dhcpcd 2>/dev/null || true
}

# Try to find the NetworkManager connection name for an interface
nm_connection_for() {
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${1}$" | cut -d: -f1 | head -1
}

# Activate an interface via NetworkManager + DHCP fallback
restore_interface() {
    local iface="$1"
    [ -z "$iface" ] && return

    if ip link show "$iface" &>/dev/null; then
        sudo ip link set "$iface" up 2>/dev/null || true
        sleep 1

        local conn
        conn=$(nm_connection_for "$iface")
        if [ -n "$conn" ]; then
            sudo nmcli connection up "$conn" 2>/dev/null || true
        else
            sudo nmcli device connect "$iface" 2>/dev/null || true
        fi
        sleep 2

        run_dhcp "$iface" 10
        sleep 2
    fi
}

# Write fallback DNS
restore_dns() {
    sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF' 2>/dev/null || true
    sudo chmod 644 /etc/resolv.conf 2>/dev/null || true
    sudo systemctl restart systemd-resolved 2>/dev/null || true
}

# ── INSTALL ─────────────────────────────────────────────────────────────────

do_install() {
    echo "============================================================================"
    echo "  HackNet v5.0 — Isolated Lab Environment Installer"
    echo "============================================================================"
    echo ""
    echo "  When HackNet runs, your lab interface moves into an isolated"
    echo "  namespace. It vanishes from 'ip a' — that's normal and safe."
    echo "  Your internet interface stays untouched."
    echo "============================================================================"
    echo ""

    # ── Detect interfaces ───────────────────────────────────────────────────
    echo "[*] Detecting network interfaces..."
    echo ""

    INTERFACES=$(ip link show | grep -E "^[0-9]+: (eth|enp|ens|wlan|wlp)" \
                 | awk -F': ' '{print $2}' | cut -d'@' -f1)

    if [ -z "$INTERFACES" ]; then
        echo "ERROR: No network interfaces found. Check your VM adapter settings."
        exit 1
    fi

    i=1
    declare -a IFACE_ARRAY
    for iface in $INTERFACES; do
        IP_ADDR=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        STATE=$(ip link show "$iface" | grep -oP '(?<=state )\w+')
        echo "  [$i] $iface  —  State: $STATE  IP: ${IP_ADDR:-none}"
        IFACE_ARRAY[$i]=$iface
        ((i++))
    done

    echo ""
    echo "Which interface connects to your VirtualBox LAB network?"
    echo "(This is the one that reaches your vulnerable VMs, NOT your internet.)"
    echo ""

    while true; do
        read -p "Enter number [1-$((i-1))]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            LAB_INTERFACE="${IFACE_ARRAY[$choice]}"
            break
        fi
        echo "Invalid. Pick 1–$((i-1))."
    done

    # Find internet interface (first one that isn't the lab)
    INTERNET_INTERFACE=""
    for iface in $INTERFACES; do
        [ "$iface" != "$LAB_INTERFACE" ] && INTERNET_INTERFACE="$iface" && break
    done
    : "${INTERNET_INTERFACE:=default}"

    echo ""
    echo "  Lab interface     : $LAB_INTERFACE"
    echo "  Internet interface: $INTERNET_INTERFACE"
    echo ""
    read -p "Correct? (yes/no): " confirm
    [ "$confirm" != "yes" ] && echo "Cancelled." && exit 0

    # ── Save config ─────────────────────────────────────────────────────────
    cat > "$CONFIG_FILE" <<EOF
LAB_INTERFACE=$LAB_INTERFACE
INTERNET_INTERFACE=$INTERNET_INTERFACE
STATIC_IP=$STATIC_IP
EOF

    echo ""
    echo "[*] Installing commands to $BIN_DIR ..."

    # Detect terminal emulator at install time and bake it in
    TERM_EMU=$(find_terminal)
    if [ -z "$TERM_EMU" ]; then
        echo "WARNING: No graphical terminal emulator found."
        echo "         hn-start will still create the namespace; you can open"
        echo "         a lab shell manually with:  sudo ip netns exec HackNet bash"
        TERM_EMU="echo_no_terminal"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # hn-start
    # ────────────────────────────────────────────────────────────────────────
    sudo tee "$BIN_DIR/hn-start" > /dev/null <<STARTEOF
#!/bin/bash
CONFIG_FILE="\$HOME/.hacknet_config"
[ ! -f "\$CONFIG_FILE" ] && echo "ERROR: Run the installer first." && exit 1
source "\$CONFIG_FILE"
NS="HackNet"
LOG_FILE="\$HOME/.hacknet_labs.log"
log_msg() { echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"; }

echo "============================================================================"
echo "  Starting HackNet — Isolated Lab Environment"
echo "============================================================================"

if [ -d "/var/run/netns/\$NS" ]; then
    echo "HackNet is already running.  Use 'hn-stop' first."
    exit 0
fi

# Verify lab interface
if ! ip link show "\$LAB_INTERFACE" &>/dev/null; then
    echo "ERROR: \$LAB_INTERFACE not found.  Re-run the installer."
    exit 1
fi

# Bring up if needed
STATE=\$(ip link show "\$LAB_INTERFACE" | grep -oP '(?<=state )\w+')
if [ "\$STATE" != "UP" ]; then
    echo "[*] Bringing \$LAB_INTERFACE up..."
    sudo ip link set "\$LAB_INTERFACE" up; sleep 2
fi

# Create namespace & move interface
echo "[*] Creating namespace \$NS ..."
sudo ip netns add \$NS
sudo ip netns exec \$NS ip link set lo up
echo "[*] Moving \$LAB_INTERFACE into namespace (it will vanish from 'ip a')..."
sudo ip link set "\$LAB_INTERFACE" netns \$NS
sudo ip netns exec \$NS ip link set "\$LAB_INTERFACE" up

# DHCP inside namespace
echo "[*] Requesting DHCP lease..."
if command -v dhcpcd &>/dev/null; then
    sudo ip netns exec \$NS dhcpcd "\$LAB_INTERFACE" -t 15 2>/dev/null || true
elif command -v dhclient &>/dev/null; then
    sudo ip netns exec \$NS dhclient -timeout 15 "\$LAB_INTERFACE" 2>/dev/null || true
fi
sleep 3

# DNS inside namespace
echo "[*] Configuring DNS inside namespace..."
sudo ip netns exec \$NS bash -c 'cat > /etc/resolv.conf <<D
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
D' 2>/dev/null || true

# Connectivity check
if sudo ip netns exec \$NS ping -c 1 -W 3 \$STATIC_IP &>/dev/null; then
    ASSIGNED_IP=\$(sudo ip netns exec \$NS ip addr show "\$LAB_INTERFACE" | grep "inet " | awk '{print \$2}' | cut -d'/' -f1)
    echo ""
    echo "SUCCESS — HackNet is ACTIVE"
    echo "  Namespace : \$NS"
    echo "  Lab iface : \$LAB_INTERFACE"
    echo "  Lab IP    : \$ASSIGNED_IP"
    echo "  Gateway   : \$STATIC_IP"
    [ "\$INTERNET_INTERFACE" != "default" ] && echo "  Internet  : \$INTERNET_INTERFACE (unchanged)"
    echo ""
    echo "  Your scans CANNOT reach the internet or school network."
    echo ""
    log_msg "START: iface=\$LAB_INTERFACE ip=\$ASSIGNED_IP gw=\$STATIC_IP"

    # Launch lab terminal
    TERM_EMU="$TERM_EMU"
    LABRC=\$(mktemp)
    cat > "\$LABRC" <<'LABEOF'
[ -f ~/.bashrc ] && source ~/.bashrc
export PS1='\[\e[1;31m\](HackNet-LAB)\[\e[0m\] \[\e[1;33m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
echo ''
echo '═══════════════════════════════════════════════════════════'
echo '  HACKNET LAB — ISOLATED NETWORK'
echo '  All traffic is contained to the VirtualBox lab network.'
echo '═══════════════════════════════════════════════════════════'
echo ''
echo 'Type "exit" to close.  Run "hn-stop" to shut down HackNet.'
echo ''
exec /bin/bash
LABEOF
    chmod +x "\$LABRC"

    if [ "\$TERM_EMU" != "echo_no_terminal" ] && command -v "\$TERM_EMU" &>/dev/null; then
        "\$TERM_EMU" -e "sudo ip netns exec \$NS bash --rcfile \$LABRC" &
        echo "Lab terminal opened (red prompt)."
    else
        echo "No GUI terminal found. Open a lab shell manually:"
        echo "  sudo ip netns exec \$NS bash"
    fi

    echo ""
    echo "Commands:  hn-status | hn-stop | hn-panic | hn-help"
else
    echo ""
    echo "FAILED: Cannot reach lab DHCP at \$STATIC_IP"
    echo ""
    echo "Cleaning up..."
    sudo ip netns exec \$NS dhcpcd -k "\$LAB_INTERFACE" 2>/dev/null || true
    sudo ip netns del \$NS 2>/dev/null || true
    sleep 1
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 3
    echo "Fix the DHCP issue and try 'hn-start' again."
    log_msg "FAIL: cannot reach \$STATIC_IP"
    exit 1
fi
STARTEOF

    # ────────────────────────────────────────────────────────────────────────
    # hn-stop
    # ────────────────────────────────────────────────────────────────────────
    sudo tee "$BIN_DIR/hn-stop" > /dev/null <<'STOPEOF'
#!/bin/bash
CONFIG_FILE="$HOME/.hacknet_config"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
NS="HackNet"
LOG_FILE="$HOME/.hacknet_labs.log"
log_msg() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

echo "============================================================================"
echo "  Stopping HackNet"
echo "============================================================================"

if [ ! -d "/var/run/netns/$NS" ]; then
    echo "HackNet is not running."
    exit 0
fi

echo "[*] Killing HackNet processes..."
pkill -f "ip netns exec $NS" 2>/dev/null || true
sleep 1

echo "[*] Releasing DHCP..."
sudo ip netns exec $NS dhcpcd -k "$LAB_INTERFACE" 2>/dev/null || true
sudo ip netns exec $NS dhclient -r "$LAB_INTERFACE" 2>/dev/null || true
sudo ip netns exec $NS pkill -9 dhcpcd 2>/dev/null || true
sleep 1

echo "[*] Deleting namespace (returning $LAB_INTERFACE)..."
sudo ip netns del $NS 2>/dev/null || true
sleep 2

# Restore DNS on host
echo "[*] Restoring DNS..."
sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF' 2>/dev/null || true
sudo chmod 644 /etc/resolv.conf 2>/dev/null || true
sudo systemctl restart systemd-resolved 2>/dev/null || true

# Restore lab interface
echo "[*] Restoring $LAB_INTERFACE..."
if ip link show "$LAB_INTERFACE" &>/dev/null; then
    sudo ip link set "$LAB_INTERFACE" up 2>/dev/null || true
    sleep 1
    sudo nmcli device connect "$LAB_INTERFACE" 2>/dev/null || true
    sleep 2
    # DHCP fallback
    if command -v dhcpcd &>/dev/null; then
        sudo dhcpcd "$LAB_INTERFACE" -t 10 2>/dev/null || true
    elif command -v dhclient &>/dev/null; then
        sudo dhclient -timeout 10 "$LAB_INTERFACE" 2>/dev/null || true
    fi
    sleep 3
    IP_ADDR=$(ip addr show "$LAB_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    echo ""
    if [ -n "$IP_ADDR" ]; then
        echo "HackNet STOPPED.  $LAB_INTERFACE restored — IP: $IP_ADDR"
        log_msg "STOP: $LAB_INTERFACE restored ip=$IP_ADDR"
    else
        echo "HackNet STOPPED.  $LAB_INTERFACE is up, waiting for DHCP..."
        log_msg "STOP: $LAB_INTERFACE up, awaiting DHCP"
    fi
else
    echo "[!] $LAB_INTERFACE not found — restarting NetworkManager..."
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 5
    if ip link show "$LAB_INTERFACE" &>/dev/null; then
        sudo ip link set "$LAB_INTERFACE" up 2>/dev/null || true
        sudo nmcli device connect "$LAB_INTERFACE" 2>/dev/null || true
        echo "$LAB_INTERFACE recovered after NetworkManager restart."
    else
        echo "ERROR: Could not recover $LAB_INTERFACE. Try 'hn-panic' or reboot."
        log_msg "STOP: ERROR could not recover $LAB_INTERFACE"
    fi
fi
echo ""
STOPEOF

    # ────────────────────────────────────────────────────────────────────────
    # hn-status
    # ────────────────────────────────────────────────────────────────────────
    sudo tee "$BIN_DIR/hn-status" > /dev/null <<'STATUSEOF'
#!/bin/bash
CONFIG_FILE="$HOME/.hacknet_config"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
NS="HackNet"

echo "============================================================================"
echo "  HackNet Status"
echo "============================================================================"
echo ""

if [ ! -d "/var/run/netns/$NS" ]; then
    echo "Status: OFFLINE"
    echo ""
    echo "Config:"
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" | sed 's/^/  /' || echo "  (none)"
    echo ""
    echo "Interfaces:"
    for iface in $LAB_INTERFACE $INTERNET_INTERFACE; do
        [ "$iface" = "default" ] && continue
        if ip link show "$iface" &>/dev/null; then
            IP=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
            echo "  $iface: ${IP:-no IP}"
        fi
    done
    exit 0
fi

echo "Status: ONLINE"
echo ""

# Namespace details
ASSIGNED_IP=$(sudo ip netns exec $NS ip addr show "$LAB_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
echo "Lab Interface : $LAB_INTERFACE"
echo "Lab IP        : ${ASSIGNED_IP:-(none)}"
echo "Gateway       : $STATIC_IP"
echo ""

echo "Isolation Check:"
if ip link show "$LAB_INTERFACE" &>/dev/null; then
    echo "  WARNING: $LAB_INTERFACE visible in main system (isolation may be broken)"
else
    echo "  OK — $LAB_INTERFACE hidden from main system"
fi
if sudo ip netns exec $NS ip link show "$LAB_INTERFACE" &>/dev/null; then
    echo "  OK — $LAB_INTERFACE visible inside namespace"
else
    echo "  PROBLEM — $LAB_INTERFACE NOT visible inside namespace"
fi
echo ""

echo "Connectivity:"
if sudo ip netns exec $NS ping -c 1 -W 2 "$STATIC_IP" &>/dev/null; then
    echo "  Lab network : REACHABLE"
else
    echo "  Lab network : UNREACHABLE"
fi
if sudo ip netns exec $NS ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo "  Internet    : REACHABLE (isolation may be compromised!)"
else
    echo "  Internet    : BLOCKED (correct — isolated)"
fi
echo ""

echo "DNS in namespace:"
sudo ip netns exec $NS cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -3 | sed 's/^/  /' \
    || echo "  (no resolv.conf)"
if sudo ip netns exec $NS timeout 2 nslookup google.com 8.8.8.8 &>/dev/null; then
    echo "  Resolution  : WORKING"
else
    echo "  Resolution  : FAILED"
fi
echo ""

echo "Routing (namespace):"
sudo ip netns exec $NS ip route 2>/dev/null | sed 's/^/  /'
echo ""

if [ -f "$HOME/.hacknet_labs.log" ]; then
    echo "Recent log entries:"
    tail -5 "$HOME/.hacknet_labs.log" | sed 's/^/  /'
fi
echo ""
STATUSEOF

    # ────────────────────────────────────────────────────────────────────────
    # hn-panic
    # ────────────────────────────────────────────────────────────────────────
    sudo tee "$BIN_DIR/hn-panic" > /dev/null <<'PANICEOF'
#!/bin/bash
CONFIG_FILE="$HOME/.hacknet_config"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
NS="HackNet"
LOG_FILE="$HOME/.hacknet_labs.log"

echo "============================================================================"
echo "  EMERGENCY PANIC — Hard Reset"
echo "============================================================================"

# Kill everything
echo "[*] Killing all HackNet processes..."
pkill -9 -f "ip netns exec $NS" 2>/dev/null || true
pkill -9 -f "dhcpcd" 2>/dev/null || true
sleep 1

# Namespace cleanup
echo "[*] Deleting namespace..."
if [ -d "/var/run/netns/$NS" ]; then
    sudo ip netns exec $NS pkill -9 dhcpcd 2>/dev/null || true
    sudo ip netns del $NS 2>/dev/null || true
    sleep 2
fi

# Restore DNS
echo "[*] Restoring DNS..."
sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF' 2>/dev/null || true
sudo chmod 644 /etc/resolv.conf 2>/dev/null || true

# Bring all interfaces UP
echo "[*] Bringing all interfaces up..."
for iface in eth0 eth1 enp0s3 enp0s8 wlan0 wlp0; do
    if ip link show "$iface" &>/dev/null; then
        sudo ip link set "$iface" up 2>/dev/null || true
        echo "  UP: $iface"
    fi
done

# DHCP on lab interface
if [ -n "$LAB_INTERFACE" ] && ip link show "$LAB_INTERFACE" &>/dev/null; then
    echo "[*] Requesting DHCP for $LAB_INTERFACE..."
    if command -v dhcpcd &>/dev/null; then
        sudo dhcpcd "$LAB_INTERFACE" -t 10 2>/dev/null || true
    elif command -v dhclient &>/dev/null; then
        sudo dhclient -timeout 10 "$LAB_INTERFACE" 2>/dev/null || true
    fi
    sleep 3
fi

# Restart networking
echo "[*] Restarting networking services..."
sudo systemctl restart systemd-resolved 2>/dev/null || true
sudo systemctl restart systemd-networkd 2>/dev/null || true
sudo systemctl restart NetworkManager 2>/dev/null || true
sleep 5

echo ""
echo "Recovery complete. Current state:"
echo ""
for iface in eth0 eth1 enp0s3 enp0s8 wlan0 wlp0; do
    if ip link show "$iface" &>/dev/null; then
        IP=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        STATE=$(ip link show "$iface" | grep -oP '(?<=state )\w+')
        echo "  $iface: $STATE  IP: ${IP:-awaiting DHCP}"
    fi
done
echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') - PANIC: emergency reset" >> "$LOG_FILE"
PANICEOF

    # ────────────────────────────────────────────────────────────────────────
    # hn-help
    # ────────────────────────────────────────────────────────────────────────
    sudo tee "$BIN_DIR/hn-help" > /dev/null <<'HELPEOF'
#!/bin/bash
cat <<'DOC'
============================================================================
  HackNet v5.0 — Isolated Lab Environment
============================================================================

WHAT IT DOES:
  Creates an isolated network namespace so your scans, exploits, and lab
  work NEVER touch the internet or school network. Your lab interface
  moves into the namespace; your internet interface stays untouched.

COMMANDS:
  hn-start     Start HackNet & open an isolated lab terminal
  hn-stop      Stop HackNet & restore your lab interface
  hn-status    Show status, isolation checks, DNS, and connectivity
  hn-panic     Emergency hard-reset if something breaks
  hn-help      This documentation

HOW IT WORKS:
  hn-start →  Lab interface disappears from 'ip a' (isolated in namespace)
              A RED terminal opens — all traffic in that terminal is
              limited to the VirtualBox lab network (192.168.25.x).
              Your internet interface is untouched.

  hn-stop  →  Lab interface returns to 'ip a', DHCP is re-requested,
              everything goes back to normal.

QUICK START:
  1.  hn-start                           # launch
  2.  (RED terminal) nmap 192.168.25.0/24  # scan safely
  3.  (main terminal) firefox              # internet works normally
  4.  hn-stop                            # done — system restored

VERIFY ISOLATION:
  $ hn-start
  $ ip a                                 # lab iface is GONE (good!)
  $ sudo ip netns exec HackNet ip a     # lab iface is HERE
  $ hn-status                            # connectivity & isolation tests
  $ hn-stop
  $ ip a                                 # lab iface is BACK

TROUBLESHOOTING:
  Can't reach lab     → Is VirtualBox running? Is DHCP VM on?
  Lost internet       → hn-stop, then: sudo systemctl restart NetworkManager
  Interface missing   → hn-panic (or reboot as last resort)
  DNS broken          → hn-status shows DNS info; hn-panic restores it

LOGS:  ~/.hacknet_labs.log
CONFIG: ~/.hacknet_config
UNINSTALL: sudo ./hacknet.sh uninstall
============================================================================
DOC
HELPEOF

    # ── Permissions & log ───────────────────────────────────────────────────
    sudo chmod +x "$BIN_DIR"/hn-start "$BIN_DIR"/hn-stop "$BIN_DIR"/hn-status \
                  "$BIN_DIR"/hn-panic "$BIN_DIR"/hn-help
    touch "$LOG_FILE"
    log_msg "INSTALL: HackNet v5.0 installed (lab=$LAB_INTERFACE internet=$INTERNET_INTERFACE)"

    echo ""
    echo "============================================================================"
    echo "  INSTALLATION COMPLETE"
    echo "============================================================================"
    echo ""
    echo "  Lab interface     : $LAB_INTERFACE"
    echo "  Internet interface: $INTERNET_INTERFACE"
    echo "  DHCP server       : $STATIC_IP"
    echo ""
    echo "  Commands:  hn-start | hn-stop | hn-status | hn-panic | hn-help"
    echo ""
    echo "  Quick start:  hn-start"
    echo "============================================================================"
}

# ── UNINSTALL ───────────────────────────────────────────────────────────────

do_uninstall() {
    echo "============================================================================"
    echo "  HackNet Uninstaller"
    echo "============================================================================"
    echo ""
    read -p "Remove HackNet and restore networking? (yes/no): " confirm
    [ "$confirm" != "yes" ] && echo "Cancelled." && exit 0
    echo ""

    # Load config if available
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # Stop HackNet if running
    if [ -d "/var/run/netns/$NS" ]; then
        echo "[*] HackNet is active — shutting down..."
        pkill -9 -f "ip netns exec $NS" 2>/dev/null || true
        sleep 1
        release_dhcp "${LAB_INTERFACE:-eth0}" "$NS"
        sleep 1
        sudo ip netns del $NS 2>/dev/null || true
        sleep 2
        echo "  Namespace deleted."
    fi

    # Restore interfaces
    echo "[*] Restoring networking..."
    restore_dns
    [ -n "$LAB_INTERFACE" ] && restore_interface "$LAB_INTERFACE"
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 3

    # Remove commands (covers both v3 and v4 command sets)
    echo "[*] Removing commands..."
    for cmd in hn-start hn-stop hn-status hn-panic hn-help hn-terminal \
               hn-internet hn-dns hn-logs hn-config; do
        sudo rm -f "$BIN_DIR/$cmd"
    done

    # Remove config
    rm -f "$CONFIG_FILE" 2>/dev/null || true

    # Logs
    echo ""
    read -p "Delete activity logs? (yes/no): " del_logs
    [ "$del_logs" = "yes" ] && rm -f "$LOG_FILE" 2>/dev/null && echo "  Logs deleted." \
        || echo "  Logs kept at: $LOG_FILE"

    # Clean orphaned namespaces
    for ns in $(sudo ip netns list 2>/dev/null | grep -i hacknet); do
        sudo ip netns del "$ns" 2>/dev/null || true
    done

    echo ""
    echo "============================================================================"
    echo "  UNINSTALL COMPLETE"
    echo "============================================================================"
    echo ""
    echo "  If networking is still broken:"
    echo "    sudo systemctl restart NetworkManager"
    echo "    sudo systemctl restart systemd-resolved"
    echo "    (or reboot)"
    echo "============================================================================"
}

# ── RECOVER ─────────────────────────────────────────────────────────────────

do_recover() {
    echo "============================================================================"
    echo "  HackNet Emergency Recovery"
    echo "============================================================================"
    echo ""
    read -p "Run emergency network recovery? (yes/no): " confirm
    [ "$confirm" != "yes" ] && echo "Cancelled." && exit 0
    echo ""

    # Kill everything
    echo "[*] Killing processes..."
    pkill -9 -f "ip netns exec" 2>/dev/null || true
    pkill -9 -f dhcpcd 2>/dev/null || true
    sleep 1

    # Delete namespace
    echo "[*] Deleting namespaces..."
    for ns in $(sudo ip netns list 2>/dev/null); do
        sudo ip netns exec "$ns" pkill -9 dhcpcd 2>/dev/null || true
        sudo ip netns del "$ns" 2>/dev/null || true
    done
    sleep 2

    # Stop networking
    echo "[*] Restarting networking stack..."
    sudo systemctl stop NetworkManager 2>/dev/null || true
    sleep 2

    # Reload network drivers
    sudo modprobe -r e1000 2>/dev/null || true
    sleep 1
    sudo modprobe e1000 2>/dev/null || true
    sleep 2

    # Bring interfaces up
    echo "[*] Bringing interfaces up..."
    for iface in eth0 eth1 enp0s3 enp0s8 wlan0 wlp0; do
        if ip link show "$iface" &>/dev/null; then
            sudo ip link set "$iface" up 2>/dev/null || true
            echo "  UP: $iface"
        fi
    done

    # Restart services
    sudo systemctl restart systemd-networkd 2>/dev/null || true
    sleep 2
    sudo systemctl start NetworkManager 2>/dev/null || true
    sleep 5

    # DHCP for known interfaces
    for iface in eth0 eth1 enp0s3 enp0s8; do
        ip link show "$iface" &>/dev/null && run_dhcp "$iface" 10
    done
    sleep 3

    # Restore DNS
    restore_dns

    # Status report
    echo ""
    echo "============================================================================"
    echo "  Recovery Complete"
    echo "============================================================================"
    echo ""
    for iface in eth0 eth1 enp0s3 enp0s8 wlan0 wlp0; do
        if ip link show "$iface" &>/dev/null; then
            IP=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
            STATE=$(ip link show "$iface" | grep -oP '(?<=state )\w+')
            echo "  $iface: $STATE  IP: ${IP:-awaiting DHCP}"
        fi
    done
    echo ""
    echo "  If interfaces are still missing, check your VM adapter settings or reboot."
    echo "============================================================================"
}

# ── MENU ────────────────────────────────────────────────────────────────────

show_menu() {
    echo "============================================================================"
    echo "  HackNet v5.0"
    echo "============================================================================"
    echo ""
    echo "  [1] Install    — Set up HackNet commands"
    echo "  [2] Uninstall  — Remove HackNet & restore networking"
    echo "  [3] Recover    — Emergency network recovery"
    echo "  [4] Quit"
    echo ""

    read -p "Choose [1-4]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_recover ;;
        *) echo "Bye." ;;
    esac
}

# ── Entry point ─────────────────────────────────────────────────────────────

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    recover)   do_recover ;;
    *)         show_menu ;;
esac
