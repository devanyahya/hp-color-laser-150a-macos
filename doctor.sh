#!/bin/bash
#
# Check every layer of the setup and say which one is broken.
#
set -uo pipefail

CONTAINER="hp-uld-spl"
SPOOL="/Users/Shared/hp-uld"
BASE_DIR="/Library/Printers/HP-ULD"

pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '        %s\n' "$*"; }
PROBLEMS=0

echo "HP ULD on macOS - health check"
echo

echo "container runtime"
if docker info >/dev/null 2>&1; then
    pass "runtime is up"
    if [ -n "$(docker ps -q -f "name=^${CONTAINER}$" 2>/dev/null)" ]; then
        pass "container $CONTAINER is running"
    else
        fail "container $CONTAINER is not running"
        note "fix: docker start $CONTAINER"
    fi
else
    fail "the container runtime is not running"
    note "fix: start Docker Desktop (and enable start-at-login)"
fi

echo
echo "spool"
if [ -d "$SPOOL" ]; then
    pass "$SPOOL exists ($(stat -f '%Sp' "$SPOOL"))"
    if [ -f "$SPOOL/heartbeat" ]; then
        age=$(( $(date +%s) - $(cat "$SPOOL/heartbeat" 2>/dev/null || echo 0) ))
        if [ "$age" -lt 60 ]; then
            pass "heartbeat is fresh (${age}s old)"
        else
            fail "heartbeat is stale (${age}s old) - the watcher is not running"
            note "fix: docker start $CONTAINER ; docker logs $CONTAINER"
        fi
    else
        fail "no heartbeat file - the container cannot see $SPOOL"
        note "fix: add $SPOOL to Docker's file sharing list, then reinstall"
    fi
else
    fail "$SPOOL is missing"
fi

echo
echo "filter and PPD"
found_filter=0
for f in "$BASE_DIR"/filter/rastertospl-*; do
    [ -f "$f" ] || continue
    found_filter=1
    owner="$(stat -f '%Su:%Sg %Sp' "$f")"
    case "$owner" in
        "root:wheel -rwxr-xr-x") pass "$(basename "$f") ($owner)" ;;
        *) fail "$(basename "$f") has wrong ownership/permissions: $owner"
           note "fix: sudo chown root:wheel '$f' && sudo chmod 755 '$f'" ;;
    esac
done
[ "$found_filter" -eq 1 ] || fail "no filter installed in $BASE_DIR/filter"

echo
echo "printer"
uris="$(lpinfo -v 2>/dev/null | awk '/^direct usb:/ {print $2}')"
if [ -n "$uris" ]; then
    pass "USB printer detected"
    printf '%s\n' "$uris" | while read -r u; do note "$(printf '%b' "${u//%/\\x}")"; done
else
    fail "no USB printer detected - check the cable and power"
fi

if pgrep -f /usr/libexec/ippusbd >/dev/null 2>&1; then
    fail "ippusbd is running - it locks the USB interface and makes the queue go offline"
    note "fix: sudo pkill -f /usr/libexec/ippusbd"
else
    pass "ippusbd is not holding the USB interface"
fi

# Killing ippusbd is not enough on its own: launchd restarts it from a
# per-printer job, so it comes straight back. The job must be disabled.
# A disabled job usually no longer appears in `launchctl list`, so both the
# live list and the disabled database have to be consulted.
live_jobs="$(launchctl list 2>/dev/null | awk -F'\t' '$3 ~ /^com\.apple\.print\.ippusb\./ {print $3}')"
off_jobs="$(launchctl print-disabled system 2>/dev/null |
            sed -n 's/.*"\(com\.apple\.print\.ippusb\.[^"]*\)" => disabled.*/\1/p')"

# Fed by here-strings, not pipes: a pipeline runs the loop in a subshell and
# the failure count would be lost.
if [ -n "$off_jobs" ]; then
    while IFS= read -r label; do
        [ -n "$label" ] && pass "launchd job disabled: $label"
    done <<< "$off_jobs"
fi
if [ -n "$live_jobs" ]; then
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        if ! printf '%s\n' "$off_jobs" | grep -Fqx "$label"; then
            fail "launchd job still enabled: $label"
            note "it will restart ippusbd and take the USB interface back"
            note "fix: sudo launchctl disable \"system/$label\""
        fi
    done <<< "$live_jobs"
fi
[ -z "$off_jobs" ] && [ -z "$live_jobs" ] && pass "no com.apple.print.ippusb launchd job registered"

echo
echo "queues"
for ppd in /etc/cups/ppd/*.ppd; do
    [ -f "$ppd" ] || continue
    grep -q "$BASE_DIR/filter/" "$ppd" 2>/dev/null || continue
    queue="$(basename "$ppd" .ppd)"
    state="$(lpstat -p "$queue" 2>/dev/null | head -1)"
    case "$state" in
        *disabled*) fail "$queue is paused: $state"
                    note "fix: cupsenable $queue" ;;
        *)          pass "${state:-$queue}" ;;
    esac
    filter="$(awk -F'"' '/^\*cupsFilter:/ {print $2}' "$ppd" | awk '{print $3}')"
    [ -x "$filter" ] || { fail "$queue points at a missing filter: $filter"; }
done

echo
recent="$(grep -c '^E ' /var/log/cups/error_log 2>/dev/null || echo 0)"
echo "recent CUPS errors: $recent (see /var/log/cups/error_log)"

echo
if [ "$PROBLEMS" -eq 0 ]; then
    printf '\033[32mEverything looks healthy.\033[0m\n'
else
    printf '\033[31m%d problem(s) found.\033[0m\n' "$PROBLEMS"
    exit 1
fi
