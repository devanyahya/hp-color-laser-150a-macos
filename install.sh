#!/bin/bash
#
# Install a working macOS print queue for HP host-based laser printers
# (Laser 10x/13x, Color Laser 15x/17x) using HP's own Linux driver in a
# container. See README.md for what this does and why.
#
set -euo pipefail

ULD_URL="https://ftp.hp.com/pub/softlib/software13/printers/CLP150/uld-hp_V1.00.39.12_00.15.tar.gz"
ULD_SHA256="cebb9b7b6125e7406634bb9c2a98b01477d1e11d66c7c90474669de9927bc91d"

IMAGE="hp-uld:local"
CONTAINER="hp-uld-spl"
SPOOL="/Users/Shared/hp-uld"
BASE_DIR="/Library/Printers/HP-ULD"
FILTER_DIR="$BASE_DIR/filter"
PPD_DIR="$BASE_DIR/ppd"
PLIST="/Library/LaunchDaemons/local.ippusbd-suppressor.plist"

QUEUE=""
PAPER="A4"
DEVICE_URI=""
PPD_NAME=""
INSTALL_SUPPRESSOR=1
RUN_SMOKE_TEST=1
KEEP_DOWNLOAD=0

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$WORK_DIR" ] && [ "$KEEP_DOWNLOAD" -eq 0 ] && rm -rf "$WORK_DIR" || true; }
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --queue NAME       CUPS queue name (default: derived from the printer model)
  --paper A4|Letter  default paper size (default: A4)
  --uri URI          device URI; only needed when several printers are attached
  --ppd FILE.ppd     force a specific PPD from HP's package
  --spool DIR        shared spool directory (default: $SPOOL)
  --no-suppressor    do not install the ippusbd suppressor LaunchDaemon
  --no-smoke-test    skip the post-install conversion check
  --keep-download    keep the downloaded HP driver tarball
  -h, --help         this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)          QUEUE="$2"; shift 2 ;;
        --paper)          PAPER="$2"; shift 2 ;;
        --uri)            DEVICE_URI="$2"; shift 2 ;;
        --ppd)            PPD_NAME="$2"; shift 2 ;;
        --spool)          SPOOL="$2"; shift 2 ;;
        --no-suppressor)  INSTALL_SUPPRESSOR=0; shift ;;
        --no-smoke-test)  RUN_SMOKE_TEST=0; shift ;;
        --keep-download)  KEEP_DOWNLOAD=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------- preflight --
say "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS only"

case "$(uname -m)" in
    arm64)  ULD_ARCH="aarch64" ;;
    x86_64) ULD_ARCH="x86_64" ;;
    *)      die "unsupported CPU architecture: $(uname -m)" ;;
esac
echo "    macOS $(sw_vers -productVersion), $(uname -m) -> HP driver arch: $ULD_ARCH"

command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop, Colima or Podman first."
docker info >/dev/null 2>&1 || die "the container runtime is not running. Start Docker Desktop and retry."
echo "    container runtime: $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null)"

# ------------------------------------------------------------ find printer --
say "Looking for the printer"

decode_uri() { printf '%b' "${1//%/\\x}"; }

if [ -z "$DEVICE_URI" ]; then
    # shellcheck disable=SC2207
    uris=($(lpinfo -v 2>/dev/null | awk '/^direct usb:/ {print $2}'))
    [ "${#uris[@]}" -gt 0 ] || die "no USB printer found. Connect and power on the printer, then retry."
    if [ "${#uris[@]}" -gt 1 ]; then
        echo "    several USB printers are attached:"
        for u in "${uris[@]}"; do echo "      $(decode_uri "$u")"; done
        die "pick one with --uri"
    fi
    DEVICE_URI="${uris[0]}"
fi

MODEL="$(decode_uri "$DEVICE_URI")"
MODEL="${MODEL#usb://}"          # HP/HP Color Laser 150?serial=...
MODEL="${MODEL#*/}"              # HP Color Laser 150?serial=...
MODEL="${MODEL%%\?*}"            # HP Color Laser 150
echo "    found: $MODEL"

if [ -z "$PPD_NAME" ]; then
    case "$MODEL" in
        *"Color Laser MFP 17"*|*"Color Laser MFP 178"*|*"Color Laser MFP 179"*)
            PPD_NAME="HP_Color_Laser_MFP_17x_Series.ppd" ;;
        *"Color Laser 15"*)
            PPD_NAME="HP_Color_Laser_15x_Series.ppd" ;;
        *"Laser MFP 13"*)
            PPD_NAME="HP_Laser_MFP_13x_Series.ppd" ;;
        *"Laser 10"*)
            PPD_NAME="HP_Laser_10x_Series.ppd" ;;
        *)
            die "no PPD known for \"$MODEL\". Pass one with --ppd (see the PPDs in HP's package)." ;;
    esac
fi
echo "    PPD: $PPD_NAME"

if [ -z "$QUEUE" ]; then
    QUEUE="$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9' '_' | sed -e 's/__*/_/g' -e 's/_$//')"
fi
echo "    queue name: $QUEUE"

FILTER_NAME="rastertospl-$(printf '%s' "$PPD_NAME" | sed -e 's/^HP_//' -e 's/_Series\.ppd$//' | tr 'A-Z' 'a-z')"

# ------------------------------------------------------- fetch HP's driver --
say "Fetching HP's Unified Linux Driver"

WORK_DIR="$(mktemp -d -t hp-uld)"
TARBALL="$WORK_DIR/uld.tar.gz"
curl -fsSL --retry 3 -o "$TARBALL" "$ULD_URL" || die "download failed: $ULD_URL"

actual="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [ "$actual" != "$ULD_SHA256" ]; then
    die "checksum mismatch for HP's package
       expected $ULD_SHA256
       got      $actual
     HP may have published a new version. Verify it yourself, then update ULD_SHA256."
fi
echo "    checksum verified"

tar xzf "$TARBALL" -C "$WORK_DIR"
for f in "uld/$ULD_ARCH/rastertospl" "uld/$ULD_ARCH/libscmssc.so" "uld/noarch/share/ppd/$PPD_NAME"; do
    [ -f "$WORK_DIR/$f" ] || die "missing from HP's package: $f"
done

# ------------------------------------------------------------ build engine --
say "Building the conversion container"

BUILD_DIR="$WORK_DIR/build"
mkdir -p "$BUILD_DIR"
cp "$WORK_DIR/uld/$ULD_ARCH/rastertospl" "$WORK_DIR/uld/$ULD_ARCH/libscmssc.so" "$BUILD_DIR/"
cp -R "$WORK_DIR/uld/noarch/share/ppd" "$BUILD_DIR/ppd"
cp "$REPO_DIR/docker/Dockerfile" "$REPO_DIR/docker/splwatch.py" "$BUILD_DIR/"

docker build -q -t "$IMAGE" "$BUILD_DIR" >/dev/null
echo "    image built: $IMAGE"

mkdir -p "$SPOOL"
chmod 0777 "$SPOOL"          # _lp writes here, Docker's file sharing reads as you

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --restart unless-stopped \
    -v "$SPOOL:/spool" "$IMAGE" >/dev/null
echo "    container started: $CONTAINER"

for _ in $(seq 1 30); do
    [ -f "$SPOOL/heartbeat" ] && break
    sleep 0.5
done
[ -f "$SPOOL/heartbeat" ] || die "the container did not produce a heartbeat in $SPOOL
     check: docker logs $CONTAINER
     if the spool is not shared with the container, add $SPOOL to Docker's file sharing list."
echo "    heartbeat present"

# --------------------------------------------------------- install to /Library --
say "Installing the CUPS filter and PPD"

# The filter must live under /Library/Printers: cupsd's sandbox refuses to
# execute anything from /usr/local.
sed -e "s|__MODEL_PPD__|$PPD_NAME|" \
    -e "s|^SPOOL_CANDIDATES=.*|SPOOL_CANDIDATES=($SPOOL)|" \
    -e "s|docker start hp-uld-spl|docker start $CONTAINER|" \
    "$REPO_DIR/macos/rastertospl-remote" > "$WORK_DIR/$FILTER_NAME"

sed -e "s|^\*cupsFilter:.*|*cupsFilter:  \"application/vnd.cups-raster 0 $FILTER_DIR/$FILTER_NAME\"|" \
    "$WORK_DIR/uld/noarch/share/ppd/$PPD_NAME" > "$WORK_DIR/patched.ppd"

# Everything needing root is collected into one reviewable script, so you are
# asked for your password once and can read exactly what will run beforehand.
ROOT_SCRIPT="$WORK_DIR/root-install.sh"
cat > "$ROOT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

install -d -o root -g wheel -m 755 "$BASE_DIR" "$FILTER_DIR" "$PPD_DIR"
install -o root -g wheel -m 755 "$WORK_DIR/$FILTER_NAME" "$FILTER_DIR/$FILTER_NAME"
install -o root -g wheel -m 644 "$WORK_DIR/patched.ppd" "$PPD_DIR/$PPD_NAME"
echo "    installed $FILTER_DIR/$FILTER_NAME"
echo "    installed $PPD_DIR/$PPD_NAME"

if [ "$INSTALL_SUPPRESSOR" -eq 1 ]; then
    cat > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.ippusbd-suppressor</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/pkill</string><string>-f</string><string>/usr/libexec/ippusbd</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>30</integer>
  <key>AbandonProcessGroup</key><true/>
</dict>
</plist>
PLIST_EOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    launchctl bootout system/local.ippusbd-suppressor 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
    pkill -f /usr/libexec/ippusbd 2>/dev/null || true
    echo "    installed $PLIST (kills ippusbd every 30s; it locks the USB interface)"
fi
EOF
chmod +x "$ROOT_SCRIPT"

echo "    the following will run as root: $ROOT_SCRIPT"
sudo /bin/bash "$ROOT_SCRIPT"

[ "$INSTALL_SUPPRESSOR" -eq 1 ] || \
    warn "skipping the ippusbd suppressor; the queue may report \"printer is offline\""

# ------------------------------------------------------------ create queue --
say "Creating the print queue"

lpadmin -p "$QUEUE" -E \
    -v "$DEVICE_URI" \
    -P "$PPD_DIR/$PPD_NAME" \
    -D "$MODEL" -L "USB" \
    -o printer-is-shared=false \
    -o printer-error-policy=retry-job \
    -o "PageSize=$PAPER" 2>&1 | grep -v 'deprecated' || true
echo "    queue \"$QUEUE\" -> $MODEL ($PAPER)"

# -------------------------------------------------------------- smoke test --
if [ "$RUN_SMOKE_TEST" -eq 1 ]; then
    say "Verifying the conversion path (no paper used)"
    raster="$WORK_DIR/smoke.raster"
    if /usr/sbin/cupsfilter -p "$PPD_DIR/$PPD_NAME" -m application/vnd.cups-raster \
            -e /etc/hosts > "$raster" 2>/dev/null && [ -s "$raster" ]; then
        bytes="$("$FILTER_DIR/$FILTER_NAME" 1 "$(id -un)" smoke-test 1 "" < "$raster" | wc -c | tr -d ' ')"
        if [ "$bytes" -gt 0 ]; then
            echo "    raster -> SPL produced $bytes bytes: the driver chain works"
        else
            die "the filter produced no data. Check: docker logs $CONTAINER"
        fi
    else
        warn "could not build a test raster; skipping (this does not mean printing is broken)"
    fi
fi

cat <<EOF

$(printf '\033[32mDone.\033[0m') Print to "$QUEUE" from any application.

Keep in mind:
  * The container must be running for printing to work. Enable
    "Start Docker Desktop when you sign in" so this survives a reboot.
  * Diagnose problems with:  ./doctor.sh
  * Watch conversions with:  docker logs -f $CONTAINER
  * Remove everything with:  ./uninstall.sh
EOF
