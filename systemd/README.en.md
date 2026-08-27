# Unit Files and udev Rules

**English** · [繁體中文](README.md)

This directory contains the **actual configuration files** taken directly from the host running this storage resilience setup. Because their installation paths across the Linux system differ, they are kept flat in a single directory here. Refer to the table below to copy each file to its respective location, then run `systemctl daemon-reload`.

| File | Install to |
|---|---|
| `ssd-recover.service` / `ssd-recover.timer` | `/etc/systemd/system/` — USB disk recovery and 60-second backstop |
| `98-rtl9210-recover.rules` | `/etc/udev/rules.d/` — Trigger recovery as soon as the bridge enumerates |
| `99-rtl9210-timeout.rules` | `/etc/udev/rules.d/` — Extended SCSI timeout for this bridge |
| `systemd-system.conf.d-10-watchdog.conf` | `/etc/systemd/system.conf.d/10-watchdog.conf` |

## Before You Enable

- **The udev rules hardcode `0bda:9210`** (Realtek RTL9210). Change this to your bridge's ID, or delete both rules if your drive is not USB.
- `ssd-recover.sh` and `root-backup.sh` invoke `/usr/local/sbin/ha-alert.sh` (Home Assistant notifications) and `/usr/local/sbin/io-health.sh` (SMART / dmesg health checks). These two scripts are host-specific and **not included in this repository**. `ha-alert.sh` is guarded with `[ -x ]` and skipped automatically if absent; **`io-health.sh` is not** — you must supply your own script or remove that line before running `root-backup.sh`.
- The layout assumed by `root-backup.sh` is documented in [`../README.md`](../README.md): root on SD card, USB drive mounted at `/mnt/ssd` with `nofail`. If the layout does not match, execution is refused. However, **read the script before trusting it with your filesystem** — it uses `rsync --delete`, and live data resides on the destination.
- `root-backup.sh` acquires `flock /run/ssd-recover.lock` to prevent the 60-second recovery timer from unmounting the drive mid-rsync.

## Post-Installation Verification

```sh
systemctl status ssd-recover.timer
udevadm test /sys/bus/usb/devices/2-1 2>&1 | grep -i ssd-recover
findmnt /mnt/ssd
tail -5 /var/lib/ssd-recover.log
```

**`ssd-recover.timer` is active (waiting) and `findmnt` shows `/mnt/ssd` mounted** → Working normally.
**`findmnt` returns nothing or `udevadm` shows no match** → The rules have not taken effect or your USB device path/ID does not match; verify the actual topology under `/sys/bus/usb/devices/`.
