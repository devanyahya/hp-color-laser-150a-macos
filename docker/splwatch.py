#!/usr/bin/env python3
"""Raster -> SPL conversion engine for HP host-based laser printers on macOS.

Runs inside a Linux container and drives HP's own `rastertospl` (from the
Unified Linux Driver). macOS keeps ownership of the USB connection; this
process only transforms bytes.

Why files instead of a socket: the macOS CUPS filter runs as user `_lp` inside
cupsd's sandbox, which blocks network access outright. A shared directory is
the only channel both sides can use.

Protocol, per job:
    filter   writes <id>.meta, then renames <id>.raster into place (the trigger)
    watcher  runs rastertospl -> <id>.spl.part -> renames to <id>.spl -> <id>.done
    filter   reads <id>.spl, then deletes <id>.spl and <id>.done

The watcher also refreshes a `heartbeat` file so the filter can fail fast with a
useful message when this container is not running.
"""
import json
import os
import subprocess
import sys
import time

FILTER = "/usr/lib/cups/filter/rastertospl"
PPD_DIR = os.environ.get("SPL_PPD_DIR", "/usr/share/cups/model/uld-hp")
PPD_DEFAULT = os.environ.get("SPL_PPD", "")
SPOOLS = [d for d in os.environ.get("SPL_SPOOLS", "/spool").split(":") if d]
POLL = 0.2
HEARTBEAT_EVERY = 5.0
STALE_AFTER = 3600.0


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def resolve_ppd(meta, spool):
    """Pick the PPD for this job.

    The queue's own PPD, shipped alongside the job, is what carries the user's
    settings: CUPS passes only explicitly-changed options on the command line
    and expects the filter to read the rest from the PPD. Falling back to the
    model PPD baked into this image would silently restore HP's stock defaults.
    """
    shipped = os.path.basename(meta.get("ppd_file", "") or "")
    if shipped:
        candidate = os.path.join(spool, shipped)
        if os.path.isfile(candidate):
            return candidate
        log("PPD antrean %r tidak ada, memakai PPD model" % shipped)

    name = os.path.basename(meta.get("ppd", "") or "")
    if name:
        candidate = os.path.join(PPD_DIR, name)
        if os.path.isfile(candidate):
            return candidate
        log("PPD %r tidak ada di %s, memakai bawaan" % (name, PPD_DIR))
    if PPD_DEFAULT and os.path.isfile(PPD_DEFAULT):
        return PPD_DEFAULT
    for name in sorted(os.listdir(PPD_DIR)):
        if name.endswith(".ppd"):
            return os.path.join(PPD_DIR, name)
    raise RuntimeError("tidak ada PPD di %s" % PPD_DIR)


def convert(spool, job_id):
    meta_path = os.path.join(spool, job_id + ".meta")
    raster_path = os.path.join(spool, job_id + ".raster")
    try:
        with open(meta_path) as fh:
            meta = json.load(fh)
    except Exception as exc:
        log("meta %s tidak terbaca: %s" % (job_id, exc))
        meta = {}

    ppd = resolve_ppd(meta, spool)
    args = [FILTER,
            str(meta.get("job", "1")),
            str(meta.get("user", "nobody")),
            str(meta.get("title", "job")),
            str(meta.get("copies", "1")),
            str(meta.get("options", ""))]
    # Log the options too: a silently-ignored setting is the failure mode this
    # pipeline is most prone to, and this line is where you see it.
    log("job %s (%s) ppd=%s opsi=%r" % (job_id, args[2], os.path.basename(ppd), args[5]))

    out_part = os.path.join(spool, job_id + ".spl.part")
    started = time.time()
    with open(raster_path, "rb") as src, open(out_part, "wb") as dst:
        proc = subprocess.run(args, stdin=src, stdout=dst, stderr=subprocess.PIPE,
                              env=dict(os.environ, PPD=ppd))
    for line in proc.stderr.decode("utf-8", "replace").splitlines():
        if line.startswith(("PAGE:", "ERROR")):
            log("  " + line)

    size = os.path.getsize(out_part)
    if proc.returncode != 0 or size == 0:
        log("job %s GAGAL (rc=%s, %d byte)" % (job_id, proc.returncode, size))
        os.rename(out_part, os.path.join(spool, job_id + ".failed"))
    else:
        os.rename(out_part, os.path.join(spool, job_id + ".spl"))
        log("job %s selesai: %d byte SPL dalam %.1fs"
            % (job_id, size, time.time() - started))

    with open(os.path.join(spool, job_id + ".done"), "w") as fh:
        fh.write("%d\n" % proc.returncode)
    for path in (raster_path, meta_path):
        try:
            os.unlink(path)
        except OSError:
            pass


def sweep_stale(spool):
    now = time.time()
    for name in os.listdir(spool):
        if name == "heartbeat":
            continue
        path = os.path.join(spool, name)
        try:
            if now - os.path.getmtime(path) > STALE_AFTER:
                os.unlink(path)
                log("buang sisa lama: %s" % name)
        except OSError:
            pass


def main():
    for spool in SPOOLS:
        os.makedirs(spool, exist_ok=True)
        sweep_stale(spool)
    log("watcher siap, mengawasi: %s" % ", ".join(SPOOLS))

    last_beat = 0.0
    while True:
        now = time.time()
        if now - last_beat >= HEARTBEAT_EVERY:
            for spool in SPOOLS:
                try:
                    path = os.path.join(spool, "heartbeat")
                    with open(path, "w") as fh:
                        fh.write("%d\n" % int(now))
                    os.chmod(path, 0o666)
                except OSError as exc:
                    log("heartbeat gagal di %s: %s" % (spool, exc))
            last_beat = now

        worked = False
        for spool in SPOOLS:
            try:
                names = sorted(os.listdir(spool))
            except OSError:
                continue
            for name in names:
                if not name.endswith(".raster"):
                    continue
                job_id = name[:-len(".raster")]
                if not os.path.exists(os.path.join(spool, job_id + ".meta")):
                    continue                    # filter belum selesai menulis
                try:
                    convert(spool, job_id)
                except Exception as exc:
                    log("job %s error tak terduga: %s" % (job_id, exc))
                    try:
                        with open(os.path.join(spool, job_id + ".done"), "w") as fh:
                            fh.write("99\n")
                    except OSError:
                        pass
                worked = True
        if not worked:
            time.sleep(POLL)


if __name__ == "__main__":
    main()
