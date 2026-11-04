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

# Run one shell script with root rights, asking for the password only once.
# In an interactive terminal sudo prompts as usual; in a non-interactive one
# (SSH without a TTY, CI, agents) sudo cannot prompt, so fall back to the
# macOS password dialog.
run_as_root() {
    if [ -t 0 ]; then
        sudo /bin/bash "$1"
    else
        osascript -e "do shell script \"/bin/bash '$1'\" with administrator privileges"
    fi
}

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

say "Removing files and restoring macOS defaults (needs administrator rights)"
# All root steps go into a single script that is elevated once — the same
# pattern install.sh already uses for its root-install.sh.
ROOT_SCRIPT="$(mktemp -t hp-uld-uninstall)"
{
    cat <<EOF
#!/bin/bash
if [ -f "$PLIST" ]; then
    launchctl bootout system/local.ippusbd-suppressor 2>/dev/null
    rm -f "$PLIST"
    echo "    $PLIST"
fi
EOF
    # Re-enable the per-printer IPP-over-USB jobs the installer switched off.
    launchctl print-disabled system 2>/dev/null |
        sed -n 's/.*"\(com\.apple\.print\.ippusb\.[^"]*\)" => disabled.*/\1/p' |
    while IFS= read -r label; do
        printf 'launchctl enable "system/%s" 2>/dev/null && echo "    re-enabled launchd job: %s"\n' \
            "$label" "$label"
    done
    cat <<EOF
[ -d "$BASE_DIR" ] && { rm -rf "$BASE_DIR"; echo "    $BASE_DIR"; }
EOF
} > "$ROOT_SCRIPT"
chmod +x "$ROOT_SCRIPT"
run_as_root "$ROOT_SCRIPT"
rm -f "$ROOT_SCRIPT"
[ -d "$SPOOL" ] && rm -rf "$SPOOL" && echo "    $SPOOL"

printf '\n\033[32mDone.\033[0m HP driver files downloaded during install were temporary and are already gone.\n'
