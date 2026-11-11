#!/bin/bash
# ============================================================================
# JioSTB C200A — Stage 1: ACS-based ADB Enable + Hardening
#
# Credits & Maintenance:
#   - Vishal Beniwal (Reddit: u/ilikechocopies): Streamlining the process & maintenance
#   - Bihaan Sen: Original research & Housekeeping-PoC
#   - ak_0o7: Exploit finding
#   - Otus9051: Consolidation
#   - Pavit Chhabra (@mesosan16 on Twitter): JHS series support
# ============================================================================
#
# ARCHITECTURE:
#   The JioSTB phones home to https://acs.oss.jio.com:8443 via CWMP (TR-069).
#   By redirecting that DNS to your host, the STB connects to your local ACS:
#
#     STB ──HTTPS──> pass_front.py (:8443, TLS term) ──HTTP──> GenieACS CWMP (:7547)
#     This script ──REST──> GenieACS NBI (:7557) ──queued tasks──> STB (next Inform)
#
#   pass_front.py handles TLS termination with the RILROOTCA cert chain,
#   session-cookie-sticky routing, and the network-check gate spoof.
#
# PREREQUISITES (see genieacs-tr069-deployment-guide.md):
#   1. GenieACS + MongoDB running in Docker:
#        cd worked_exploit/tls && docker compose up -d
#   2. pass_front.py running (TLS front-end):
#        cd worked_exploit/tls && python3 pass_front.py &
#   3. DNS redirect: acs.oss.jio.com → your host LAN IP
#      (router DNS override, dnsmasq, Pi-hole, etc.)
#   4. STB rebooted after DNS redirect is active
#   5. pycryptodome installed: pip install pycryptodome
#
# Usage:
#   ./stage1.sh                                  # auto-discover device
#   ./stage1.sh --nbi URL --device ID            # non-interactive
#   ./stage1.sh --stb-ip 192.168.x.x            # specify STB IP for ADB
#   ./stage1.sh --list-devices                   # show devices in GenieACS
#   ./stage1.sh --tasks-only                     # queue tasks, skip ADB wait
#   ./stage1.sh --skip-prereqs                   # skip prerequisite checks
#   ./stage1.sh http://IP:7557 DEVICE_ID         # legacy positional args
#
# Environment (override any default):
#   NBI_URL     GenieACS NBI endpoint   (default: http://127.0.0.1:7557)
#   STB_IP      STB's LAN IP for ADB   (default: auto-discover)
#   TLS_PORT    pass_front.py port      (default: 8443)

set -euo pipefail

# ── PATH & Binary Resolution ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TLS_DIR="$SCRIPT_DIR/tls"

case ":$PATH:" in
    *":$SCRIPT_DIR:"*) ;;
    *) PATH="$SCRIPT_DIR:$PATH"; export PATH ;;
esac

ADB_BIN="$SCRIPT_DIR/adb.exe"
if [ ! -f "$ADB_BIN" ] && [ ! -x "$ADB_BIN" ]; then
    ADB_BIN="adb"
fi

# ── Python Interpreter Resolution ─────────────────────────────
pick_python() {
    local c
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "import Crypto" >/dev/null 2>&1; then
            echo "$c"; return 0
        fi
    done
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}
PY="$(pick_python)" || { echo "  Python not found — install Python 3 and tick 'Add to PATH'"; exit 1; }
export PY

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
BCYAN='\033[1;36m'; BYELLOW='\033[1;33m'; BMAGENTA='\033[1;35m'
BGREEN='\033[1;32m'; BWHITE='\033[1;37m'; BOLD='\033[1m'

# ── Configurable defaults ──────────────────────────────────────
NBI_URL="${NBI_URL:-http://127.0.0.1:7557}"
TLS_PORT="${TLS_PORT:-8443}"
DEVICE_ID=""
SERIAL=""
STB_IP="${STB_IP:-}"
SKIP_PREREQS=false
LIST_ONLY=false
TASKS_ONLY=false
DOCTOR=false
WATCH_MODE=false
SIMULATE_MODE=false
SHOW_TASKS=false
CLEAR_TASKS=false
STOP_FRONT=false
YES_DISABLE_TR069=true
ADB_PORT=5555
INFORM_INTERVAL=360
STALE_THRESHOLD=900  # 15 minutes — device not seen since = stale

# ── Argument parsing ───────────────────────────────────────────
usage() {
    echo "Usage: $0 [OPTIONS] [NBI_URL] [DEVICE_ID]"
    echo ""
    echo "Options:"
    echo "  --nbi URL             GenieACS NBI endpoint"
    echo "  --device ID           Full device ID (skip discovery)"
    echo "  --serial SN           STB serial number (matches against device IDs)"
    echo "  --stb-ip IP           STB LAN IP for ADB connection"
    echo "  --tls-port PORT       TLS front-end port (default: 8443)"
    echo "  --list-devices        Run health check, list devices in GenieACS and exit"
    echo "  --tasks-only          Queue TR-069 tasks only, skip ADB"
    echo "  --skip-prereqs        Skip prerequisite checks"
    echo "  --doctor              Run chain diagnostic health check"
    echo "  --watch               Watch for STB Inform connection in real-time"
    echo "  --simulate            Simulate synthetic CWMP Inform to prove PC chain"
    echo "  --tasks               Show active tasks queued for the STB"
    echo "  --clear-tasks         Clear pending tasks queued for the STB"
    echo "  --stop, --stop-front  Stop background pass_front.py process"
    echo "  --yes-disable-tr069   (Legacy no-op; TR-069 & bloat removal is now always enabled)"
    echo "  -h, --help            Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nbi)               NBI_URL="$2"; shift 2 ;;
        --device)            DEVICE_ID="$2"; shift 2 ;;
        --serial)            SERIAL="$2"; shift 2 ;;
        --stb-ip)            STB_IP="$2"; shift 2 ;;
        --tls-port)          TLS_PORT="$2"; shift 2 ;;
        --skip-prereqs)      SKIP_PREREQS=true; shift ;;
        --list-devices)      LIST_ONLY=true; shift ;;
        --tasks-only)        TASKS_ONLY=true; shift ;;
        --doctor)            DOCTOR=true; shift ;;
        --watch)             WATCH_MODE=true; shift ;;
        --simulate)          SIMULATE_MODE=true; shift ;;
        --tasks)             SHOW_TASKS=true; shift ;;
        --clear-tasks)       CLEAR_TASKS=true; shift ;;
        --stop|--stop-front) STOP_FRONT=true; shift ;;
        --yes-disable-tr069) YES_DISABLE_TR069=true; shift ;;
        -h|--help)           usage ;;
        *)
            if [[ "$1" == http* ]]; then NBI_URL="$1"
            elif [[ -z "$DEVICE_ID" && "$1" != -* ]]; then DEVICE_ID="$1"
            fi
            shift ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────
log()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
die()  { fail "$@"; exit 1; }

json_py() { "$PY" -c "import sys,json; $1" 2>/dev/null; }

# URL-encode a device ID for NBI paths
url_encode() { "$PY" -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(),safe=''))" <<< "$1"; }

banner() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}            ${BCYAN}JioSTB C200A — Stage 1: TR-069 ADB Enable${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                       ║${NC}"
    echo -e "${CYAN}║  ${BYELLOW}★ Streamlined & Maintained by:${NC}                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║    ${BMAGENTA}✦ ${BWHITE}Vishal Beniwal ${BYELLOW}(Reddit: u/ilikechocopies)${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                       ║${NC}"
    echo -e "${CYAN}║  ${BCYAN}Credits & Contributors:${NC}                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║    • ${BWHITE}Bihaan Sen, ak_0o7${NC} (Research & Exploit)                          ${CYAN}║${NC}"
    echo -e "${CYAN}║    • ${BWHITE}Otus9051${NC} (Consolidation)                                         ${CYAN}║${NC}"
    echo -e "${CYAN}║    • ${BWHITE}Pavit Chhabra${NC} (${BYELLOW}@mesosan16${NC} on Twitter - JHS support)              ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
}

# Early routing commands (Doctor / Watch / Simulate / Stop)
if [ "$STOP_FRONT" = true ]; then
    echo -e "${YELLOW}Stopping pass_front.py processes...${NC}"
    if [ -f "$TLS_DIR/pass_front.pid" ]; then
        PID=$(cat "$TLS_DIR/pass_front.pid" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
            rm -f "$TLS_DIR/pass_front.pid"
            log "pass_front.py (PID $PID) stopped."
        fi
    fi
    "$PY" -c "
import os, sys
try:
    import psutil
    for p in psutil.process_iter(['pid', 'name', 'cmdline']):
        cmd = ' '.join(p.info.get('cmdline') or [])
        if 'pass_front.py' in cmd:
            p.terminate()
            print(f'Terminated pass_front process PID {p.pid}')
except Exception:
    pass
" 2>/dev/null || true
    echo -e "${GREEN}Done.${NC}"
    exit 0
fi

if [ "$DOCTOR" = true ]; then
    "$PY" "$SCRIPT_DIR/doctor.py" --nbi "$NBI_URL" --tls-port "$TLS_PORT" ${STB_IP:+--stb-ip "$STB_IP"}
    exit $?
fi

if [ "$SIMULATE_MODE" = true ]; then
    "$PY" "$SCRIPT_DIR/doctor.py" --simulate --nbi "$NBI_URL" --tls-port "$TLS_PORT"
    exit $?
fi

if [ "$WATCH_MODE" = true ]; then
    "$PY" "$SCRIPT_DIR/doctor.py" --watch --nbi "$NBI_URL" ${STB_IP:+--stb-ip "$STB_IP"}
    exit $?
fi

banner

queue_task() {
    local desc="$1"
    local payload="$2"

    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        "$NBI_URL/devices/$DEV_ENC/tasks" \
        -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || echo -e "\n000")
    CODE=$(echo "$RESP" | tail -1)

    case "$CODE" in
        200) log "$desc — applied (device was connected)" ;;
        202) log "$desc — queued for next Inform" ;;
        *)   warn "$desc — HTTP $CODE (task may still apply)" ;;
    esac
}

queue_task_once() {
    local desc="$1"
    local match_target="$2"
    local payload="$3"

    local existing_tasks
    existing_tasks=$(curl -s "$NBI_URL/tasks/?query=%7B%22device%22%3A%22$DEV_ENC%22%7D" 2>/dev/null || echo "[]")

    local already_queued
    already_queued=$("$PY" -c "
import sys, json
try:
    tasks = json.loads(sys.argv[1])
    match = sys.argv[2]
    for t in tasks:
        if t.get('name') == match:
            sys.exit(0)
        for p in t.get('parameterValues', []):
            if len(p) > 0 and match in str(p[0]):
                sys.exit(0)
except Exception:
    pass
sys.exit(1)
" "$existing_tasks" "$match_target" && echo "yes" || echo "no")

    if [ "$already_queued" = "yes" ]; then
        log "$desc — already in queue, skipping duplicate"
        return 0
    fi

    queue_task "$desc" "$payload"
}

# ═══════════════════════════════════════════════════════════════
# [1/6] Prerequisite checks + auto-start services
# ═══════════════════════════════════════════════════════════════
PASS_FRONT_LAUNCHED=false
PASS_FRONT_PID=""
KEEP_PASS_FRONT=true

cleanup() {
    if [ -n "$PASS_FRONT_PID" ] && kill -0 "$PASS_FRONT_PID" 2>/dev/null; then
        if [ "$KEEP_PASS_FRONT" = true ]; then
            echo ""
            echo -e "  ${CYAN}pass_front.py left running (pid $PASS_FRONT_PID) so the STB can keep informing.${NC}"
            echo -e "  ${CYAN}Stop it later with:  kill $PASS_FRONT_PID  (or  $0 --stop)${NC}"
        else
            echo ""
            echo -e "  ${CYAN}Stopping pass_front.py (pid $PASS_FRONT_PID)...${NC}"
            kill "$PASS_FRONT_PID" 2>/dev/null || true
            wait "$PASS_FRONT_PID" 2>/dev/null || true
            rm -f "$TLS_DIR/pass_front.pid"
        fi
    fi
}
trap cleanup EXIT
trap 'KEEP_PASS_FRONT=false; cleanup; exit 130' INT TERM

port_open() {
    "$PY" -c "
import socket,sys; s=socket.socket(); s.settimeout(1.0)
try:
    s.connect(('127.0.0.1',int(sys.argv[1])))
    s.close()
    sys.exit(0)
except ConnectionRefusedError:
    sys.exit(1)
except Exception:
    # TLS server accepted connection then closed — port is open
    sys.exit(0)
" "$1" 2>/dev/null
}

if [ "$SKIP_PREREQS" = false ]; then
    echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v "$PY" >/dev/null 2>&1 || die "Python ($PY) not found"
    
    HAS_CRYPTO=$("$PY" -c "import Crypto; print('yes')" 2>/dev/null || echo "no")
    if [ "$HAS_CRYPTO" = "yes" ]; then
        log "Python interpreter: $PY (pycryptodome available)"
    else
        log "Python interpreter: $PY (pycryptodome not installed — precomputed token fallback active)"
    fi

    if [ "$TASKS_ONLY" = false ]; then
        command -v "$ADB_BIN" >/dev/null 2>&1 || die "adb not found ($ADB_BIN)"
        log "ADB binary: $ADB_BIN"
    fi

    # GenieACS NBI reachable?
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$NBI_URL/devices/" 2>/dev/null || echo "000")
    if [ "$HTTP" = "000" ]; then
        fail "Cannot reach GenieACS NBI at $NBI_URL"
        echo -e "    Start GenieACS: ${CYAN}cd $TLS_DIR && docker compose up -d${NC}"
        exit 1
    fi
    log "GenieACS NBI reachable ($NBI_URL)"

    # TLS front-end — auto-launch pass_front.py if not running
    TLS_RUNNING=false
    if port_open 8443 && port_open 9443; then
        log "TLS front-end already listening on :8443 + :9443"
        TLS_RUNNING=true
    elif port_open 8443; then
        log "TLS front-end listening on :8443 (port 9443 not open)"
        TLS_RUNNING=true
    elif port_open 9443; then
        log "TLS front-end listening on :9443 (port 8443 not open)"
        TLS_RUNNING=true
    fi

    if [ "$TLS_RUNNING" = false ]; then
        if [ -f "$TLS_DIR/pass_front.py" ]; then
            echo -ne "  ${CYAN}Starting pass_front.py...${NC} "
            # Honour a custom TLS_CERT (e.g. a chain generated for JHS-series boxes)
            TLS_CERT="${TLS_CERT:-$TLS_DIR/acs_chain.pem}" \
                "$PY" "$TLS_DIR/pass_front.py" </dev/null >>"$TLS_DIR/pass_front.log" 2>&1 &
            PASS_FRONT_PID=$!
            echo "$PASS_FRONT_PID" > "$TLS_DIR/pass_front.pid"
            sleep 2
            if kill -0 "$PASS_FRONT_PID" 2>/dev/null && port_open 8443; then
                if port_open 9443; then
                    log "pass_front.py started (pid $PASS_FRONT_PID, ports 8443+9443)"
                else
                    log "pass_front.py started (pid $PASS_FRONT_PID, port 8443)"
                fi
                PASS_FRONT_LAUNCHED=true
            else
                fail "pass_front.py failed to start — check $TLS_DIR/pass_front.log"
                exit 1
            fi
        else
            die "pass_front.py not found at $TLS_DIR/pass_front.py"
        fi
    fi

    echo ""

    # If we just launched pass_front, the STB needs a reboot to connect to us
    if [ "$PASS_FRONT_LAUNCHED" = true ]; then
        echo -e "${YELLOW}  pass_front.py was just started.${NC}"
        echo -e "  ${CYAN}Make sure DNS redirect is active (acs.oss.jio.com -> your LAN IP),${NC}"
        echo -e "  ${CYAN}then cold power-cycle the STB (unplug wall power) so it connects to your ACS.${NC}"
        echo ""
    fi
else
    echo -e "${YELLOW}[1/6] Prerequisite checks skipped${NC}"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# [2/6] Device discovery
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[2/6] Finding device in GenieACS...${NC}"

DEVICES_JSON=$(curl -s "$NBI_URL/devices/?projection=_id,_lastInform" 2>/dev/null || echo "[]")

# Annotate each device with staleness + online status
DEVICES_ANNOTATED=$("$PY" -c "
import sys, json, datetime
threshold = $STALE_THRESHOLD
now = datetime.datetime.now(datetime.timezone.utc)
devices = json.load(sys.stdin)
for d in devices:
    li = d.get('_lastInform')
    if li:
        try:
            ts = datetime.datetime.fromisoformat(li.replace('Z','+00:00'))
            age = (now - ts).total_seconds()
            d['_age_s'] = int(age)
            d['_online'] = age < threshold
        except: d['_age_s'] = -1; d['_online'] = False
    else:
        d['_age_s'] = -1; d['_online'] = False
json.dump(devices, sys.stdout)
" <<< "$DEVICES_JSON" 2>/dev/null || echo "[]")

DEVICE_COUNT=$(json_py "print(len(json.load(sys.stdin)))" <<< "$DEVICES_ANNOTATED" || echo "0")
DEVICE_COUNT="${DEVICE_COUNT:-0}"
ONLINE_COUNT=$(json_py "print(sum(1 for d in json.load(sys.stdin) if d.get('_online')))" <<< "$DEVICES_ANNOTATED" || echo "0")

# Helper: format device list with status
print_device_list() {
    local filter_arg="${1:-all}"  # "all" or "online"
    "$PY" -c "
import sys, json
filt = '$filter_arg'
for i, d in enumerate(json.load(sys.stdin), 1):
    did = d.get('_id', '?')
    age = d.get('_age_s', -1)
    online = d.get('_online', False)
    if filt == 'online' and not online:
        continue
    if online:
        status = '\033[0;32mONLINE\033[0m'
    elif age > 0:
        if age < 3600: ago = f'{age//60}m ago'
        elif age < 86400: ago = f'{age//3600}h ago'
        else: ago = f'{age//86400}d ago'
        status = f'\033[1;33mSTALE ({ago})\033[0m'
    else:
        status = '\033[0;31mNEVER SEEN\033[0m'
    print(f'    {i}) {did}  [{status}]')
" <<< "$DEVICES_ANNOTATED"
}

if [ "$LIST_ONLY" = true ]; then
    echo -e "${CYAN}Checking PC-side chain before listing devices...${NC}"
    "$PY" "$SCRIPT_DIR/doctor.py" --quick --nbi "$NBI_URL" --tls-port "$TLS_PORT" || true
    echo ""
    if [ "$DEVICE_COUNT" = "0" ]; then
        echo -e "${YELLOW}  No devices found in GenieACS.${NC}"
        echo -e "  Note: The STB only connects on boot. If the PC chain is running,"
        echo -e "  perform a cold power-cycle (unplug the STB power cord from the wall),"
        echo -e "  wait 5 seconds, and plug it back in."
    else
        print_device_list all
    fi
    exit 0
fi

if [ "$DEVICE_COUNT" = "0" ]; then
    fail "No devices found in GenieACS."
    echo ""
    echo -e "  The STB hasn't connected yet. Checklist:"
    echo -e "    1. DNS redirect active: ${CYAN}acs.oss.jio.com${NC} -> your host LAN IP"
    echo -e "    2. pass_front.py running on :$TLS_PORT"
    echo -e "    3. GenieACS Docker stack running (cwmp :7547, nbi :7557)"
    echo -e "    4. Cold power-cycle the STB (unplug wall power), then wait up to 6 minutes"
    echo ""
    echo -e "  Diagnose PC-side chain: ${CYAN}$0 --doctor${NC}"
    echo -e "  Test full fake Inform:  ${CYAN}$0 --simulate${NC}"
    echo -e "  Watch for connection:   ${CYAN}$0 --watch${NC}"
    exit 1
fi

# --- Resolve device ID from --device, --serial, or interactive ---
if [ -n "$DEVICE_ID" ]; then
    EXISTS=$(json_py "
d=json.load(sys.stdin)
print('yes' if any(x['_id']=='$DEVICE_ID' for x in d) else 'no')
" <<< "$DEVICES_ANNOTATED")
    if [ "$EXISTS" != "yes" ]; then
        fail "Device '$DEVICE_ID' not found in GenieACS."
        echo "  Available devices:"
        print_device_list all
        exit 1
    fi
    log "Device found: $DEVICE_ID"

elif [ -n "$SERIAL" ]; then
    DEVICE_ID=$(json_py "
import sys
serial = '$SERIAL'
for d in json.load(sys.stdin):
    if serial in d.get('_id', ''):
        print(d['_id']); break
" <<< "$DEVICES_ANNOTATED")
    if [ -z "$DEVICE_ID" ]; then
        fail "No device matching serial '$SERIAL'."
        echo "  Available devices:"
        print_device_list all
        exit 1
    fi
    log "Matched serial $SERIAL -> $DEVICE_ID"

else
    if [ "$ONLINE_COUNT" = "1" ] && [ "$DEVICE_COUNT" = "1" ]; then
        DEVICE_ID=$(json_py "print(json.load(sys.stdin)[0]['_id'])" <<< "$DEVICES_ANNOTATED")
        log "Auto-selected device: $DEVICE_ID"
    else
        if [ "$ONLINE_COUNT" -ge 1 ] 2>/dev/null; then
            echo -e "  ${GREEN}$ONLINE_COUNT online${NC}, $DEVICE_COUNT total:"
        else
            echo -e "  $DEVICE_COUNT devices (${YELLOW}none currently online${NC}):"
        fi
        print_device_list all
        echo ""
        echo -e "  ${CYAN}Enter device number, serial number, or 'wait' to wait for a new device:${NC}"
        echo -ne "  > "
        read -r CHOICE

        if [ "$CHOICE" = "wait" ]; then
            echo -e "  ${CYAN}Waiting for a device to connect (cold reboot the STB)...${NC}"
            PREV_SNAPSHOT=$(json_py "
d={x['_id']:x.get('_lastInform','') for x in json.load(sys.stdin)}
print(repr(d))
" <<< "$DEVICES_ANNOTATED")
            for attempt in $(seq 1 120); do
                sleep 5
                printf "\r  Waiting... %ds" "$((attempt * 5))"
                FRESH=$(curl -s "$NBI_URL/devices/?projection=_id,_lastInform" 2>/dev/null || echo "[]")
                NEW_DEV=$("$PY" -c "
import sys, json
prev = $PREV_SNAPSHOT
devices = json.load(sys.stdin)
for d in devices:
    did = d.get('_id','')
    li = d.get('_lastInform','')
    if did not in prev:
        print(did); break
    if li and li != prev.get(did,''):
        print(did); break
" <<< "$FRESH" 2>/dev/null || true)
                if [ -n "$NEW_DEV" ]; then
                    echo ""
                    DEVICE_ID="$NEW_DEV"
                    log "Device connected: $DEVICE_ID"
                    break
                fi
            done
            [ -z "$DEVICE_ID" ] && die "Timed out waiting for device."
        elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] 2>/dev/null; then
            DEVICE_ID=$(json_py "
d=json.load(sys.stdin)
i=int('$CHOICE')-1
print(d[i]['_id'] if 0<=i<len(d) else '')
" <<< "$DEVICES_ANNOTATED")
            [ -z "$DEVICE_ID" ] && die "Invalid selection."
        else
            DEVICE_ID=$(json_py "
serial = '$CHOICE'
for d in json.load(sys.stdin):
    if serial in d.get('_id', ''):
        print(d['_id']); break
" <<< "$DEVICES_ANNOTATED")
            [ -z "$DEVICE_ID" ] && die "No device matching '$CHOICE'."
        fi
        log "Selected: $DEVICE_ID"
    fi
fi

# Warn if selected device is stale
DEVICE_ONLINE=$(json_py "
for d in json.load(sys.stdin):
    if d['_id']=='$DEVICE_ID':
        print('yes' if d.get('_online') else 'no'); break
" <<< "$DEVICES_ANNOTATED" || echo "no")
if [ "$DEVICE_ONLINE" != "yes" ]; then
    DEVICE_AGE=$(json_py "
for d in json.load(sys.stdin):
    if d['_id']=='$DEVICE_ID':
        a=d.get('_age_s',-1)
        if a<0: print('never')
        elif a<3600: print(f'{a//60}m ago')
        elif a<86400: print(f'{a//3600}h ago')
        else: print(f'{a//86400}d ago')
        break
" <<< "$DEVICES_ANNOTATED")
    warn "Device last seen $DEVICE_AGE — it may be offline."
    echo -e "  ${CYAN}Cold power-cycle the STB (unplug wall power) to force it to reconnect to your ACS.${NC}"
    echo -e "  ${CYAN}Tasks will queue and apply once it comes back online.${NC}"
    echo ""
fi

DEV_ENC=$(url_encode "$DEVICE_ID")

echo -e "  ${CYAN}NBI:${NC}    $NBI_URL"
echo -e "  ${CYAN}Device:${NC} $DEVICE_ID"
echo ""

# Tasks inspection / cleanup options
if [ "$SHOW_TASKS" = true ]; then
    echo -e "${CYAN}Current tasks in GenieACS queue for device $DEVICE_ID:${NC}"
    "$PY" -c "
import sys, json, urllib.request, urllib.parse
nbi = '$NBI_URL'.rstrip('/')
dev = urllib.parse.quote('$DEVICE_ID')
url = f'{nbi}/tasks/?query=%7B%22device%22%3A%22{dev}%22%7D'
try:
    with urllib.request.urlopen(url) as r:
        tasks = json.loads(r.read())
        if not tasks:
            print('  Queue is empty (no pending tasks).')
        for i, t in enumerate(tasks, 1):
            name = t.get('name', 'unknown')
            fault = t.get('fault')
            fault_str = f' [FAULT: {fault}]' if fault else ''
            pvals = t.get('parameterValues', [])
            p_str = ', '.join([f'{p[0]}={p[1]}' for p in pvals]) if pvals else ''
            print(f'  {i}. {name} {p_str}{fault_str}')
except Exception as e:
    print('  Failed to query tasks:', e)
"
    exit 0
fi

if [ "$CLEAR_TASKS" = true ]; then
    echo -e "${YELLOW}Clearing pending tasks for device $DEVICE_ID...${NC}"
    "$PY" -c "
import sys, json, urllib.request, urllib.parse
nbi = '$NBI_URL'.rstrip('/')
dev = urllib.parse.quote('$DEVICE_ID')
url = f'{nbi}/tasks/?query=%7B%22device%22%3A%22{dev}%22%7D'
try:
    with urllib.request.urlopen(url) as r:
        tasks = json.loads(r.read())
        for t in tasks:
            tid = t.get('_id')
            if tid:
                dreq = urllib.request.Request(f'{nbi}/tasks/{tid}', method='DELETE')
                urllib.request.urlopen(dreq)
        print(f'  Cleared {len(tasks)} task(s).')
except Exception as e:
    print('  Failed to clear tasks:', e)
"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# [3/6] Refresh device data model
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[3/6] Refreshing device data model...${NC}"
echo -e "  ${CYAN}Populates all TR-069 parameters from the device.${NC}"

queue_task_once "refreshObject (full tree)" "refreshObject" \
    '{"name":"refreshObject","objectName":""}'

echo ""

# ═══════════════════════════════════════════════════════════════
# [4/6] Queue TR-069 parameter changes
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[4/6] Queuing TR-069 tasks...${NC}"
echo -e "  ${CYAN}Tasks apply when the STB sends its next Inform (~${INFORM_INTERVAL}s).${NC}"
echo -e "  ${CYAN}Cold power-cycle the STB to trigger an immediate boot Inform.${NC}"
echo ""

queue_task_once "Enable USB Debugging" "Device.JioSTB.USB.USBDebugging" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.USB.USBDebugging",true,"xsd:boolean"]
    ]
}'

queue_task_once "Set Debug Validity (2037)" "Device.JioSTB.USB.DebugValidityDate" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.USB.DebugValidityDate","2037-01-01T00:00:00.000Z","xsd:dateTime"]
    ]
}'

queue_task_once "Disable FOTA + Enable Downgrade" "Device.JioSTB.FOTA.Disable" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.FOTA.Disable","true","xsd:string"],
        ["Device.JioSTB.FOTA.DowngradeEnable","true","xsd:string"],
        ["Device.JioSTB.FOTA.DowngradeValidityDate","2037-12-31T23:59:59.000Z","xsd:dateTime"]
    ]
}'

echo ""

if [ "$TASKS_ONLY" = true ]; then
    echo -e "${GREEN}Tasks queued. The STB will apply them on its next Inform.${NC}"
    echo -e "Cold power-cycle the STB (unplug wall power) to trigger an immediate Inform."
    echo -e "Once ADB is enabled, connect: ${CYAN}$ADB_BIN connect <STB_IP>:$ADB_PORT${NC}"
    echo -e "Then re-run with ${CYAN}--skip-prereqs --stb-ip <IP>${NC} to finish post-setup."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# [5/6] ADB connection
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[5/6] Connecting via ADB...${NC}"

ADB_TARGET=""

# If no STB IP given, check for an already-connected device first, then ask
if [ -z "$STB_IP" ]; then
    EXISTING=$("$ADB_BIN" devices 2>/dev/null | grep -E 'device$' | head -1 | awk '{print $1}' || true)
    if [ -n "$EXISTING" ]; then
        ADB_TARGET="$EXISTING"
        STB_IP="${EXISTING%%:*}"
        log "Using already-connected device: $ADB_TARGET"
    else
        echo -e "  ${CYAN}Enter the STB's LAN IP (check your router's DHCP page):${NC}"
        echo -ne "  > "
        read -r STB_IP
        [ -z "$STB_IP" ] && die "STB IP required. Find it and re-run with --stb-ip <IP>"
    fi
fi

if [ -z "$ADB_TARGET" ]; then
    ADB_TARGET="$STB_IP:$ADB_PORT"
    echo -e "  ${CYAN}Trying $ADB_BIN connect $ADB_TARGET ... (Ctrl+C to abort)${NC}"
    FOUND=0
    for i in $(seq 1 60); do
        OUT=$("$ADB_BIN" connect "$ADB_TARGET" 2>&1 || true)
        if echo "$OUT" | grep -qi "connected"; then
            FOUND=1; break
        fi
        printf "\r  Attempt %d/60 (%ds)..." "$i" "$((i * 5))"
        sleep 5
    done
    echo ""
    [ "$FOUND" = "0" ] && die "Could not connect to $ADB_TARGET — is ADB enabled and STB booted?"
fi

log "ADB connected ($ADB_TARGET)"

adb_cmd() {
    if [ -n "$ADB_TARGET" ]; then
        "$ADB_BIN" -s "$ADB_TARGET" "$@" 2>/dev/null
    else
        "$ADB_BIN" "$@" 2>/dev/null
    fi
}

# Wait for ADB authorization — TV displays an RSA key prompt on first connect
ADB_STATE=$(adb_cmd get-state || echo "unknown")
if [ "$ADB_STATE" != "device" ]; then
    echo -e "  ${YELLOW}Waiting for ADB authorization...${NC}"
    echo -e "  ${CYAN}Check your TV screen — accept the RSA key prompt when it appears.${NC}"
    echo -e "  ${CYAN}(Note: 'unauthorized' status is normal until you accept the prompt on TV)${NC}"
    for i in $(seq 1 60); do
        ADB_STATE=$(adb_cmd get-state || echo "unknown")
        if [ "$ADB_STATE" = "device" ]; then break; fi
        if [ "$ADB_STATE" = "unauthorized" ] && [ $((i % 5)) -eq 0 ]; then
            # Re-issue connect in case prompt was accepted
            "$ADB_BIN" connect "$ADB_TARGET" >/dev/null 2>&1 || true
        fi
        printf "\r  Waiting for auth... %ds" "$((i * 2))"
        sleep 2
    done
    echo ""
    [ "$ADB_STATE" != "device" ] && die "ADB not authorized after 120s. Accept the prompt on the TV and retry."
fi

log "ADB authorized"
echo ""

# ═══════════════════════════════════════════════════════════════
# [6/6] ADB post-setup
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[6/6] Configuring device via ADB...${NC}"

adb_sh() { adb_cmd shell "$@"; }

# shellcheck source=lib/adb_helpers.sh
source "$SCRIPT_DIR/lib/adb_helpers.sh"

# Enable Developer Options & ADB global setting
adb_sh "settings put global device_provisioned 1"
adb_sh "settings put global development_settings_enabled 1"
adb_sh "settings put global adb_enabled 1" >/dev/null 2>&1 || true
log "Device provisioned + Developer Options enabled"

# Completely delete Jio OTA, TR-069, remote command, scheduler, and ad packages (disable if undeletable)
for pkg in \
    com.jio.httpupdate \
    com.jio.usbupdate \
    com.jio.tr069client \
    com.rjil.jio.stb.commandreceiver \
    com.jio.backgroundscheduler \
    com.jio.stbadservice
do
    remove_or_disable_pkg "$pkg" true
done

# Also remove or disable JHS (Iwedia / JioOS 2.0) OTA services if present
for pkg in \
    com.iwedia.httpupdate \
    com.iwedia.updateservice \
    com.iwedia.pvodupdateservice \
    com.iwedia.updatercuotaservice
do
    remove_or_disable_pkg "$pkg" false
done

# Install APKs in the folder strictly one-by-one
# Priority: Monet Launcher first, then Shizuku/Shevery, then any others (excluding AnExplorer and Stremio)
echo -e "  Installing APKs from folder (one-by-one)..."
APKS=()

# 1. Monet Launcher first
for apk in "$SCRIPT_DIR"/*[Mm]onet*.apk; do
    [ -f "$apk" ] && APKS+=("$apk")
done

# 2. Shizuku / Shevery second
for apk in "$SCRIPT_DIR"/*[Ss]hizuku*.apk "$SCRIPT_DIR"/*[Ss]hevery*.apk; do
    [ -f "$apk" ] && APKS+=("$apk")
done

# 3. Any other remaining APKs in the folder
for apk in "$SCRIPT_DIR"/*.apk; do
    [ -f "$apk" ] || continue
    case "$(basename "$apk")" in
        *[Aa]n[Ee]xplorer*|*[Ss]tremio*|*[Mm]onet*|*[Ss]hizuku*|*[Ss]hevery*) continue ;;
    esac
    APKS+=("$apk")
done

TOTAL_APKS=${#APKS[@]}
APK_COUNT=0

if [ "$TOTAL_APKS" -gt 0 ]; then
    idx=1
    for apk in "${APKS[@]}"; do
        apk_name="$(basename "$apk")"
        echo -ne "    ${CYAN}[$idx/$TOTAL_APKS]${NC} Installing $apk_name... "
        INSTALL_OUT=$(adb_cmd install -r -g "$apk" 2>&1 || true)
        if ! echo "$INSTALL_OUT" | grep -qi "Success"; then
            INSTALL_OUT=$(adb_cmd install -r "$apk" 2>&1 || true)
        fi

        if echo "$INSTALL_OUT" | grep -qi "Success"; then
            echo -e "${GREEN}Success${NC}"
            APK_COUNT=$((APK_COUNT + 1))
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
        sleep 2
        idx=$((idx + 1))
    done
    [ "$APK_COUNT" -gt 0 ] && log "Installed $APK_COUNT of $TOTAL_APKS APK(s)"
fi

# Activate Monet Launcher and ensure it survives reboot
if pkg_installed_for_user "com.klevico.monet"; then
    adb_sh "pm grant com.klevico.monet android.permission.WRITE_SECURE_SETTINGS 2>/dev/null || true"
    log "Granted WRITE_SECURE_SETTINGS to Monet Launcher"

    # Launch Monet once to verify rendering
    adb_sh "am start -n com.klevico.monet/.HomeActivity 2>/dev/null || true"
    sleep 1

    # JioService re-enables stock launcher at boot, but 'pm suspend' persists across reboots
    adb_sh "pm suspend --user 0 com.iwedia.ui.rjio.launcher.reliance 2>/dev/null || true"
    adb_sh "pm disable-user --user 0 com.iwedia.ui.rjio.launcher.reliance 2>/dev/null || true"
    adb_sh "cmd package set-home-activity com.klevico.monet/.HomeActivity 2>/dev/null || true"
    adb_sh "input keyevent KEYCODE_HOME 2>/dev/null || true"
    log "Monet Launcher set as active home (stock launcher suspended to prevent boot ad reversion)"
fi

# Grant Shevery (Shizuku-compatible API) all permissions so ADB can be re-enabled through it if needed
for pkg in "com.hamondev.shevery" "moe.shizuku.privileged.api"; do
    if pkg_installed_for_user "$pkg"; then
        grant_shevery_permissions "$pkg"
    fi
done

echo ""
echo -e "${GREEN}Stage 1 complete.${NC}"
echo ""
echo "  Done:"
echo "    - USB debugging enabled (expires 2037)"
echo "    - FOTA / OTA, TR-069 client, command receiver, scheduler & ad service deleted (or disabled if protected)"
echo "    - Firmware downgrade enabled"
echo "    - Developer Options enabled"
echo "    - Shevery granted full permissions, AppOps & battery exemption (can re-enable ADB if needed)"
[ "$APK_COUNT" -gt 0 ] && echo "    - $APK_COUNT app(s) installed"
echo ""
echo -e "${BYELLOW}★ Process Streamlined & Maintained by:${NC}"
echo -e "  ${BMAGENTA}✦ ${BWHITE}Vishal Beniwal ${BYELLOW}(Reddit: u/ilikechocopies)${NC}"
echo ""
echo -e "${BCYAN}Credits & Contributors:${NC}"
echo -e "  • Bihaan Sen, ak_0o7 (Research & Exploit)"
echo -e "  • Otus9051 (Tool Consolidation)"
echo -e "  • Pavit Chhabra (@mesosan16 on Twitter - JHS series support)"
