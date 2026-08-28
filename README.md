# Surviving a flaky USB SSD on a Raspberry Pi 4

**English** · [繁體中文](README.zh-TW.md)

The probe host was crashing whenever the desk was bumped. This is what was actually
wrong, and the three bugs found while proving the fix works — including two that would
have left the machine dead and unreachable.

Hardware: RPi 4, DietPi on Debian 13, USB SSD behind a **Realtek RTL9210B-CG**
(`0bda:9210`), root filesystem on that SSD.

## The four things that were wrong

Only the first is obvious.

**1. Root lived on the removable disk.** A momentary contact glitch on a USB connector
should cost you a mount. It should not cost you the kernel. With root on the SSD, every
flicker was fatal.

**2. UAS was bound to the bridge.** `/sys/bus/usb/drivers/uas/2-1:1.0`, no quirks set
anywhere. RPi 4 + RTL9210 + UAS is a well-known stall combination.

**3. USB3 link power management was failing every boot:**

```
usb 2-1: enable of device-initiated U1 failed
```

LPM negotiation failing is a classic source of spurious disconnects and is easy to miss
because the device works anyway.

**4. There was no evidence, and that was structural.** The persistent journal was
bind-mounted from a directory **on the SSD**, and `/var/log` is a 50 MB tmpfs (DietPi
ramlog). So when the disk dropped, the log of the disk dropping died with it.
`journalctl --list-boots` showed one boot. Months of crashes, zero forensics.

> If you are debugging intermittent storage, check where your logs live **first**.
> Everything else is guessing until that is fixed.

## The fix

**Invert the roles.** Root on the SD card; the SSD demoted to a `nofail` data mount.

```
# /etc/fstab
PARTUUID=<ssd>  /mnt/ssd  ext4  nofail,noatime,x-systemd.device-timeout=10,x-systemd.mount-timeout=20  0 0
/mnt/ssd/var/lib/<app>  /var/lib/<app>  none  bind,nofail,x-systemd.requires=/mnt/ssd  0 0
```

Plus `RequiresMountsFor=` on the service that uses the data, so it cannot start against
an empty mountpoint and quietly corrupt its own state.

**Harden the bridge** on the kernel command line:

```
usb-storage.quirks=0bda:9210:u    # IGNORE_UAS -> bulk-only transport
usbcore.quirks=0bda:9210:k        # NO_LPM -> stop the U1/U2 negotiation that was failing
usbcore.autosuspend=-1
```

and give the SCSI layer room to retry instead of giving up, via udev:

```
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
```

Confirmation it took effect:

```
usb 2-1: UAS is ignored for this device, using usb-storage instead
usb-storage 2-1:1.0: Quirks match for vid 0bda pid 9210: 800000
```

and the `U1 failed` line stops appearing. Cost: sequential read drops to ~153 MB/s
without command queuing. For bulk storage that is a fine trade; it is still several times
an SD card.

> **Order matters.** Apply the USB quirks only *after* root is off the SSD. If bulk-only
> transport turns out to break your bridge while root still lives on it, the machine will
> not boot — and you may not be there to fix it.

## Three bugs found by actually testing it

None of these show up until you pull the disk. Simulate it at the bus level:

```
echo 2-1 > /sys/bus/usb/drivers/usb/unbind    # yank
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # plug back in
```

**Bug 1 — the bridge does not come back on its own.** After a rebind it re-enumerates
(`lsusb` sees it, `usb-storage` attaches, a SCSI host is created) and then **no block
device ever appears**. It loops on:

```
usb 2-1: reset SuperSpeed USB device number 2 using xhci_hcd
```

A SCSI host rescan (`echo "- - -" > /sys/class/scsi_host/host0/scan`) does **not** fix
it. What does, reliably, first attempt, every time:

```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 4
echo 1 > /sys/bus/usb/devices/2-1/authorized
```

Deauthorising forces a genuine re-enumeration instead of the half-initialised reset loop.
This is the single most useful thing in this document.

**Bug 2 — the udev rule can never fire.** The obvious trigger is the block device:

```udev
ACTION=="add", KERNEL=="sda1", ...        # WRONG
```

But `sda1` is exactly what recovery has to *create*. Chicken and egg: the rule waits
forever for the thing it is supposed to produce. Trigger on the USB bridge instead — and
match `bind` as well as `add`, because a driver-level rebind emits `bind`:

```udev
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="9210", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ssd-recover.service"
```

**Bug 3 — systemd start-rate-limiting fights you exactly when it matters.** Default is 5
starts per 10 s. A flapping connector blows straight through that and systemd then
*refuses* to start the recovery unit. Set `StartLimitIntervalSec=0`, and take a
`flock -n` in the script so overlapping triggers step aside instead of fighting over the
device.

## The recovery ladder

[`scripts/ssd-recover.sh`](scripts/ssd-recover.sh), triggered by udev and by a 60 s
backstop timer:

1. Fast path — already mounted and writable, do nothing.
2. Stale mount whose device vanished → stop the one service holding handles, then
   `umount -l`. **Not** `fuser -k -m`, which would take Docker and everything else with it.
3. Up to 4 attempts of: SCSI rescan → `authorized` toggle → `usb-storage` unbind/rebind.
4. Mount, then **verify it did not land read-only** and pass a write smoke test. Only if
   that fails, run `e2fsck -p`; refuse to mount and alert if it returns ≥ 2. Never
   auto-fsck a healthy disk, and never fsck a half-connected one on a hunch.
5. Re-bind the data mount, restart the dependent service.

Measured, hands-off, from a real disconnect:

```
20:07:20  --- trigger=udev ---
20:07:26  authorized toggle on /sys/bus/usb/devices/2-1
20:07:42  sda1 present after 1 attempt(s)
20:07:42  mounted /mnt/ssd rw -> service restarted -> recovery complete
```

22 seconds. During the outage the OS never blinked: root writable, Docker, Home
Assistant, Tailscale, SSH and the probe all stayed up, systemd unmounted the dead disk
cleanly with no zombie mount, and the data service stopped itself rather than running
against an empty directory.

## When the software fixes stop working, prove *which* layer failed

Two weeks later the same host started dropping the disk again — this time with root safely
on the SD card, every quirk above verified active, and the drive completely idle. The
alerts said "I/O error delta 12". That number tells you something is wrong and nothing
about what.

The signature that settles it is in `dmesg`:

```
usb 2-1: USB disconnect, device number 6
usb 2-1: new SuperSpeed USB device number 7 using xhci_hcd   <- 0.3 s later
```

A **disconnect followed by a fresh enumeration** is not a command timeout, not UAS, and
not a link-power-management failure. None of those detach the device. Something in the
physical path — connector, cable, or the bridge itself — actually broke the link. No
kernel parameter fixes that, so stop looking for one.

That still leaves two very different physical faults, and they need different parts:

|  | drive lost 5 V | data link broke, drive stayed powered |
|---|---|---|
| blame | power contact, cable resistance, host current budget | SuperSpeed pairs: connector wear, cable quality, the bridge |
| fix | powered hub, shorter/thicker cable | reseat, different port, USB 2.0, new enclosure |

**SMART tells you which, for free.** Attributes `12 Power_Cycle_Count` and
`192 Power-Off_Retract_Count` advance only when the drive genuinely loses power. Sample
them at the moment of each drop:

```
smartctl -A -d sat /dev/sda | awk '$1==12||$1==192||$1==194'
```

Across ten link drops on this machine both counters stayed **flat** — and across two
deliberate physical unplugs the same evening `Power_Cycle_Count` moved **2867 → 2869**.
The counter works; the drops simply never removed power. Verdict: SuperSpeed signal
integrity, not the power rail.

Which also ranks the fixes. The other USB3 port is worth one try because it changes the
connector contact, but it reuses the same controller and the same cable. **A USB 2.0 port
is the real escalation**: USB2 does not use the SuperSpeed pairs at all and runs at
480 Mb/s instead of 5 Gb/s, so it has orders of magnitude more signal margin. You trade
~150 MB/s for ~40 MB/s. For a media or backup volume that is a bargain — here it turned a
weekly 20 GB backup from 3 minutes into 10. If USB2 also drops, the enclosure is dead;
replace it.

One caveat on `-d sat`: an RTL9210B fronts both NVMe and SATA drives, and smartmontools
guesses NVMe. If `-d sntrealtek`, `-d sntasmedia` and `-d auto` all fail with
`unsupported scsi opcode`, there is a **SATA** M.2 behind the bridge and `-d sat` is the
one that works.

### Yes, those really are lost writes

`Buffer I/O error on dev sda1 ... lost async page write` means the write was **dropped,
not retried**, and each disconnect also produced `Aborting journal` and
`JBD2: I/O error when updating journal superblock`. It survived here only because the
volume was idle: every lost block was ext4 metadata, so the `EXT4-fs (sda1): recovery
complete` on the next mount replayed it, and `dumpe2fs -h` still reports `state: clean`
with `FS Error count 0`.

Do not read that as harmless. Under real write load, `data=ordered` loses the in-flight
*data* pages silently — journal replay does not bring those back. A disk that
re-enumerates every 90 seconds is not "self-healing", it is a disk that has not yet been
asked to write anything important.

## Do not page a human for a failure you already fixed

The recovery ladder above worked 17 times out of 17. Every one of those successes also
sent a phone notification, because the health check alerted on a *symptom counter* rather
than on an outcome. A night of "I/O error delta 12 (warning 1/3)" pushes teaches the owner
to swipe them away, which is precisely how the one that matters gets missed.

The rule that survives contact with a real incident:

- **Recovery succeeded → log it, do not notify.** It is a non-event.
- **Recovery failed → notify immediately**, and say what still works. "OS is fine, root is
  on SD, qbittorrent stays down" is actionable; "I/O error delta 12" is not.
- **Rate, not incidents → notify once.** Three drops in an hour means the hardware is
  dying even though every single one was repaired. Cap it at one message per hour.
- **A daily digest that is silent on a clean day.** Nothing to report is the common case,
  and a scheduled "all good" message is just training in ignoring you.

[`scripts/ssd-linkwatch.sh`](scripts/ssd-linkwatch.sh) implements the drop accounting and
the rate alert; [`scripts/ssd-report.sh`](scripts/ssd-report.sh) is the on-demand and daily
digest. Both write to the **SD card**, so the evidence outlives the disk being diagnosed.

## The hardcoded port path that would have broken all of it, silently

Everything above referred to `/sys/bus/usb/devices/2-1` — including the `authorized`
toggle, which is the only step that actually revives this bridge, and the `2-1:1.0`
usb-storage rebind. That path is the **physical port**. Move the plug one socket over and
it becomes `2-2`, or `1-1.3` on a USB2 port, and the recovery ladder quietly stops being
able to recover anything. Nothing errors; it just never works again.

Resolve the device by its vendor and product ID instead:

```bash
# usbdev-rtl9210.sh — print the bridge's sysfs path, wherever it is plugged in
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")" = "0bda" ] || continue
  [ "$(cat "$d/idProduct")" = "9210" ] || continue
  echo "$d"; exit 0
done
exit 1
```

```bash
USBDEV=$(/usr/local/sbin/usbdev-rtl9210.sh) || USBDEV=/sys/bus/usb/devices/2-1
USBIF="$(basename "$USBDEV"):1.0"      # for the usb-storage unbind/bind
```

Worth auditing the rest of the setup for the same class of bug while you are there. Here
the udev rules already keyed on `idVendor`/`idProduct`, `fstab` used `PARTUUID`, and the
kernel quirks in `cmdline.txt` keyed on `0bda:9210` — all port-independent. Only the two
scripts were pinned to a socket, which is exactly the kind of thing that is invisible
until the day you move the cable to fix something else.

## The answer was the socket

Moving the enclosure to the other USB3 port on the same host, and fixing the Pi and the
enclosure physically in place, ended it:

| | before | after |
|---|---|---|
| link drops | one every 40–90 s | **0 in 9 h 43 min** |
| USB device number | walked 3 → 10 in five hours | **stayed at 30** |
| `dmesg` | a disconnect every minute | nothing since the mount |
| filesystem | journal replay on every drop | `clean`, `FS Error count 0` |

Then a deliberate soak, because "no drops while idle" proves very little about a bus:
4 GiB written at 104 MB/s, read back at 291 MB/s, then a simultaneous read and write pass.
The device number never moved, no new I/O errors, SSD peaked at 43 °C. The link holds
under sustained load.

So the fault was the **socket contact and plug seating** — not the cable, not the bridge,
not the drive. That is the least interesting of the possible answers and it was still worth
the whole diagnostic ladder to reach, because every cheaper explanation had already been
eliminated by evidence rather than by guessing: SMART said the drive was healthy, the power
counters said the drive never lost 5 V, `get_throttled` said the host never browned out,
and the drops happened at idle, at 34 °C, with every kernel quirk verified active. The USB2
fallback was never needed.

### What the resilience work actually bought

It did not fix the hardware. It made the hardware failure *survivable while the hardware
failure was being found*, which is a different and more useful property:

- **17 automatic recoveries, 0 failures.** Every drop was repaired without a human.
- **The OS never blinked.** Root on the SD card, so a disk that vanished 27 times in one
  session took down nothing: Docker, Home Assistant, Tailscale, SSH and the network probe
  all stayed up, and systemd unmounted the dead disk cleanly every time.
- **No data was lost**, and the reason is worth being honest about: the volume happened to
  be idle. `data=ordered` loses in-flight data pages silently on an aborted journal. This
  was survivable, not safe.

<!-- The uncomfortable half. -->
And it has a cost that is easy to miss: **automatic recovery converts a hardware failure
into silence.** A disk re-enumerating every 90 seconds looked, from the outside, like a
working machine. Recovery machinery must therefore report the *rate* of what it repaired,
not just the failures it could not — otherwise it hides exactly the trend you needed.

## Two ways a health check became the fault

Both of these were found on this box, both were caused by monitoring rather than by
hardware, and both are the kind of thing that only shows up in production.

**A check that counts log lines is not counting incidents.** The I/O health check derived
its alert from a cumulative `grep -c` over the kernel ring buffer, with `reset SuperSpeed`
in the pattern. Each re-enumeration emits four of those lines, so every drop was
double-counted — and an ordinary maintenance replug, which produces ~20 re-enumerations,
scored a delta of 104. That crossed the *instant* threshold, wrote the alert file, and the
weekly root backup refuses to run while that file exists. A false positive had silently
disarmed the backup. Link events now belong to the watcher that counts distinct incidents;
the health check counts only real I/O failures.

**Installing a package for its CLI can enable a daemon that feeds your health signal.**
`smartmontools` was installed to get `smartctl` for the diagnosis above. That also enabled
`smartd`, which cannot monitor a drive behind this USB bridge and exits `status=17`, *"No
devices to monitor"*, one second after starting. Harmless on its own — except the outbound
heartbeat derives its degraded flag from `systemctl --failed` being non-empty. Every ping
for the next ten hours carried the failure suffix. The external watchdog is edge-triggered,
so it sent one email and then went quiet, which means **the degraded channel was saturated:
a real fault afterwards would have produced no change in the signal at all.**

A stuck alarm is worse than no alarm, because it looks like an alarm. Two rules came out of
it: after any `apt install` on a box whose health signal is derived from `systemctl
--failed`, check `systemctl --failed` before walking away; and never fix this class of
problem with an ignore-list, because an ignore-list that grows is how a dead-man switch
quietly stops meaning anything. Disable what does not work instead — `smartctl` on the
command line is unaffected, and it was the only SMART path any of these scripts used.

## Two more things worth copying

**A watchdog you did not check is a watchdog you do not have.** The BCM2835 hardware
watchdog caps at 15 s — `cat /sys/class/watchdog/watchdog0/timeout`. Request 10 s and
systemd will report 15 s; request 30 s and you silently get 15 s anyway. Plan around the
real ceiling.

**Every alert your box can raise dies with the box.** Notifications routed through a
service running *on* the machine tell you nothing about a power cut, a dead card, or a
kernel wedge. Add an outbound heartbeat to something external, so silence itself is the
alert. [`cf-heartbeat/`](https://github.com/Hydr0neFN/hinet-dual-path-probe/tree/main/cf-heartbeat) is a small Cloudflare Worker that does this —
KV for last-seen, a Cron Trigger to notice the silence, Email Routing to send the mail.
