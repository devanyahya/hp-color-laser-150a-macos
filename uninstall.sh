#!/bin/bash
#
# Remove everything install.sh created. Safe to run more than once.
#
set -uo pipefail

CONTAINER="hp-uld-spl"
IMAGE="hp-uld:local"
SPOOL="/Users/Shared/hp-uld"
BASE_DIR="/Library/Printers/HP-ULD"
PLIST="/Library/LaunchDaemons/local.ippusbd-suppressor.plist"
KEEP_IMAGE=0

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-image) KEEP_IMAGE=1; shift ;;
        --spool)      SPOOL="$2"; shift 2 ;;
        -h|--help)    echo "Usage: ./uninstall.sh [--keep-image] [--spool DIR]"; exit 0 ;;
        *)            echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

say "Removing print queues that use this driver"
for ppd in /etc/cups/ppd/*.ppd; do
    [ -f "$ppd" ] || continue
    if grep -q "$BASE_DIR/filter/" "$ppd" 2>/dev/null; then
        queue="$(basename "$ppd" .ppd)"
        echo "    $queue"
        cancel -a "$queue" 2>/dev/null
        lpadmin -x "$queue" 2>/dev/null
    fi
done

say "Removing the container"
docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "    $CONTAINER" || echo "    (not running)"
if [ "$KEEP_IMAGE" -eq 0 ]; then
    docker rmi "$IMAGE" >/dev/null 2>&1 && echo "    image $IMAGE" || true
fi

say "Removing files (needs administrator rights)"
sudo -v
if [ -f "$PLIST" ]; then
    sudo launchctl bootout system/local.ippusbd-suppressor 2>/dev/null
    sudo rm -f "$PLIST"
    echo "    $PLIST"
fi
[ -d "$BASE_DIR" ] && sudo rm -rf "$BASE_DIR" && echo "    $BASE_DIR"
[ -d "$SPOOL" ]    && rm -rf "$SPOOL"         && echo "    $SPOOL"

printf '\n\033[32mDone.\033[0m HP driver files downloaded during install were temporary and are already gone.\n'
