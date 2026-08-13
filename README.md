# HP host-based lasers on macOS

HP never shipped a macOS driver for the **HP Laser 10x/13x** and **HP Color Laser 15x/17x**
series — only Windows and Linux. These are host-based printers: they speak SPL-C/QPDL
and cannot render PostScript or PCL themselves, so generic drivers produce nothing.

This project runs **HP's own Linux driver inside a container**, while **macOS keeps
ownership of the USB connection**. You print from any app to a normal print queue.

Tested on macOS 26.3 (Apple Silicon) with an HP Color Laser 150a.

```
Application
    │
    ▼
CUPS (macOS)  ──►  cgpdftoraster  ──►  rastertospl-remote          ← CUPS filter, /bin/bash
                                              │
                                    /Users/Shared/hp-uld           ← shared spool directory
                                              │
                                   container: rastertospl          ← HP's Linux driver, native arm64
                                              │
                                          SPL / QPDL
                                              │
                                    CUPS usb backend  ──►  printer
```

## Supported printers

| Series | Models | PPD used |
|---|---|---|
| HP Laser 10x | 107a, 107w, 108a, 108w | `HP_Laser_10x_Series.ppd` |
| HP Laser MFP 13x | 135a, 135w, 137fnw | `HP_Laser_MFP_13x_Series.ppd` |
| HP Color Laser 15x | 150a, 150nw | `HP_Color_Laser_15x_Series.ppd` |
| HP Color Laser MFP 17x | 178nw, 179fnw | `HP_Color_Laser_MFP_17x_Series.ppd` |

Printing only. Scanning on the MFP models is not covered.

## Requirements

- macOS on Apple Silicon or Intel
- A container runtime: Docker Desktop, Colima or Podman — it must be running to print
- Administrator rights (the filter goes into `/Library/Printers`)

## Install

```sh
git clone https://github.com/devanyahya/hp-color-laser-150a-macos.git
cd hp-color-laser-150a-macos
./install.sh
```

The installer detects the connected printer, downloads HP's Unified Linux Driver
straight from `ftp.hp.com`, verifies its SHA-256, builds the container image,
installs the CUPS filter and PPD, creates the queue, and finishes with a
conversion self-test that uses no paper.

Useful flags: `--queue NAME`, `--paper Letter`, `--uri URI` (several printers
attached), `--ppd FILE.ppd`, `--no-suppressor`. See `./install.sh --help`.

Enable **"Start Docker Desktop when you sign in"** so printing survives a reboot.

```sh
./doctor.sh      # check every layer and report what is broken
./uninstall.sh   # remove queue, container, filter, PPD, LaunchDaemon
```

## Print options that actually do something

HP's PPD advertises more options than the driver implements. Measured on the
Color Laser 15x by converting the same page and comparing output bytes:

| Option | Effect | Notes |
|---|---|---|
| `Quality=600x600_2` / `_1` | **yes** | Best / Normal |
| `BlackOptimization=False` | **yes** | composite black instead of K-only; smoother greys |
| `secBrightness=0..100` | **yes** | 50 is neutral, lower is darker |
| `secContrast=0..100` | **yes** | |
| `secSaturation=0..100` | **yes** | |
| `CyanRed` / `MagentaGreen` / `YellowBlue` | **yes** | colour balance, 0..100 |
| `Trapping=Off/Medium/Maximum` | **yes** | small |
| `EdgeEnhance=Off` | **yes** | `Normal` and `Maximum` are identical |
| `MediaType=...` | **yes** | sets `@PJL SET PAPERTYPE`, changes fuser behaviour |
| `Screen=Normal/Enhanced/Detailed` | **no** | byte-identical output; the driver never reads it |
| `secRGB=Standard/Vivid/Device/...` | **no** | byte-identical output |
| `TonerSaveMode=Save` | **no** | byte-identical output |
| `DocumentType=Photo/...` | **no** | a JCL option whose choices emit an empty string — only `X-Ray` sends any PJL |

Example:

```sh
lp -d HP_Color_Laser_150 -o BlackOptimization=False -o secBrightness=40 file.pdf
```

### Saving toner: `TonerSaveMode` does nothing, use these instead

The PPD offers `TonerSaveMode`, but both of its choices carry an empty code
string, and the output is byte-identical either way. It is dead on these models.

What actually works:

| Setting | Effect on one test page |
|---|---|
| `ColorModel=Gray` | `@PJL SET COLORMODE = MONO`, black cartridge only — 900 KB → 244 KB |
| `secBrightness=70` (50 is neutral, higher is lighter) | lighter overall |
| both together | 202 KB |

Grayscale is the big one on a colour laser: it leaves the three colour
cartridges untouched. Rather than trading quality away on your main queue, add a
second queue against the same device for drafts:

```sh
lpadmin -p HP_150a_Draft -E -v "$(lpinfo -v | awk '/usb:/ {print $2}')" \
    -P /Library/Printers/HP-ULD/ppd/HP_Color_Laser_15x_Series.ppd \
    -o ColorModel=Gray -o secBrightness=70 -o Quality=600x600_1
```

### Read this before judging print quality: "Best" is the worse setting

`Quality=600x600_2` is labelled **Best** in the PPD and is HP's default. It renders
mid-tones as a coarse **horizontal line screen** — visible stripes with white gaps
that never merge, worst in light and mid tones, tolerable only where the ink is
dense enough for the lines to fuse.

`Quality=600x600_1`, labelled **Normal**, is dramatically smoother. Both emit
`HWResolution [600 600]`; the suffix selects an internal halftone mode, not a
resolution. The installer therefore sets `600x600_1` as the queue default.

```sh
lpadmin -p YOUR_QUEUE -o Quality=600x600_1 -o BlackOptimization=False
```

Do not judge this from the output size, which is the trap that hid it here for a
long time: "Best" produces roughly **twice** the SPL data of "Normal" and still
looks worse. Print both and compare on paper.

`BlackOptimization=False` helps mid-tones a little more on top of that (composite
CMY instead of K-only).

Things that genuinely cannot be changed, verified so you need not repeat it:

- `Screen` in every value produces byte-identical output, and the driver prints no
  complaint about the value — that code path never reads it.
- The `JCL`-prefixed keywords found in the binary (`JCLDocumentType`,
  `JCLDarkenText`) change nothing either.
- Dropping `_scms` from the PPD's `*Emulators` line does not disable Smart CMS —
  it is selected from an internal model table, and the driver still demands
  8-bit RGB input. There is no path where the host does the halftoning.
- `MediaType=Thick` raises the fuser temperature via PJL but does not make the
  line screen merge.

## Known limitations

- **No printer status.** Paper jams, empty trays and low toner are not reported
  back to macOS. The USB back-channel is read by the CUPS backend but nothing
  parses SPL status, so CUPS only knows the data was sent.
- **The container must be running.** If it is not, jobs fail immediately with a
  clear message rather than hanging — the filter checks a heartbeat file first.
- **No scanning** for MFP models.

## What made this hard

Four macOS behaviours break the obvious implementations, each of them silently.
They are documented here so the next person does not have to rediscover them.

1. **cupsd sandboxes filters and blocks network access.** A first version had the
   filter POST the raster to the container over `127.0.0.1`; `curl` failed with
   exit 7 in 0 ms while the port was demonstrably listening. Hence the shared
   directory.
2. **`/bin/sh` and `/usr/bin/python3` are shims.** Both resolve through
   `/private/var/select/…`, which user `_lp` may not open. A filter starting with
   `#!/bin/sh` dies with `Operation not permitted` and exit 126. Use `/bin/bash`.
3. **Filters cannot live in `/usr/local`.** The sandbox only allows the blessed
   driver locations such as `/Library/Printers`.
4. **`umask 0000` is mandatory in the filter.** Files created by `_lp` with mode
   0600 appear as `-?????????` inside the container, because Docker's file
   sharing runs as the logged-in user. The job then sits there doing nothing.

Two more traps worth knowing:

- **`ippusbd` locks the USB interface.** These printers advertise IPP-over-USB
  (class 7/1, protocol 4) on *alternate setting 1*, so macOS starts
  `/usr/libexec/ippusbd` on connect. It never manages to use the printer — the
  Add Printer dialog still asks for a driver — but it holds the interface, and
  the queue reports *"printer is offline"* or *"Unable to send data to printer"*.
  Even `root` cannot claim the interface with libusb, so OpenPrinting's
  `ipp-usb` does not help either.

  Killing the process is not a fix: macOS registers a **per-printer launchd job**
  named `com.apple.print.ippusb.<make>.<model>.<serial>` that restarts it
  immediately, so a periodic `pkill` loses the race more often than it wins.
  The installer disables that job, which launchd remembers across reboots:

  ```sh
  launchctl list | awk -F'\t' '$3 ~ /^com\.apple\.print\.ippusb\./ {print $3}'
  sudo launchctl disable "system/<the label>"
  ```

  `uninstall.sh` re-enables it. A `pkill` LaunchDaemon is still installed as a
  safety net for a job that appears after installation.
- **`lpadmin -m everywhere` cannot be used with a `usb://` URI.** CUPS 2.3 parses
  the host part as a network name and fails with `Unable to connect to "HP:0"`.
  `ipp2ppd` has the same defect.

## Legal

This repository contains **no HP code**. `install.sh` downloads HP's Unified
Linux Driver from HP's own servers at install time and verifies its checksum.
HP's binaries and PPDs remain under HP's licence; the scripts here are MIT.

## Contributing

Reports from other models in these series are especially welcome — say which
model, which macOS version, and paste the output of `./doctor.sh`. Findings
about status reporting (parsing the SPL back-channel) would close the biggest
functional gap.
