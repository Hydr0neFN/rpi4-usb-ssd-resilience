#!/bin/bash
# Standing report on USB SSD link health. Reads only persistent state on the SD card,
# so it is valid after a reboot and after the SSD has been away.
#   ssd-report.sh          -> print the report
#   ssd-report.sh --notify -> print it, and push a digest to HA ONLY if something happened
LOG=/var/lib/ssd-linkwatch.log
RLOG=/var/lib/ssd-recover.log
NOTIFY=0
[ "${1:-}" = "--notify" ] && NOTIFY=1

drops_since() { awk -v s="$1" '$2=="LINK-DROP" && $1 > s' "$LOG" 2>/dev/null | wc -l; }
H1=$(drops_since "$(date -d '1 hour ago'  -Is)")
H6=$(drops_since "$(date -d '6 hours ago' -Is)")
H24=$(drops_since "$(date -d '24 hours ago' -Is)")
PCTS=$(awk '$2 ~ /^PORT-CHANGE/{t=$1} END{print t}' "$LOG" 2>/dev/null)
if [ -n "$PCTS" ]; then
  HCFG=$(drops_since "$PCTS")
  CFGAGE=$(( ( $(date +%s) - $(date -d "$PCTS" +%s) ) / 60 ))
  CFGLINE="since last port change ($PCTS, ${CFGAGE} min ago): $HCFG drops"
else
  CFGLINE="no PORT-CHANGE marker logged"
fi

USBDEV=$(/usr/local/sbin/usbdev-rtl9210.sh 2>/dev/null)
PORT=$([ -n "$USBDEV" ] && basename "$USBDEV" || echo ABSENT)
SPEED=$([ -n "$USBDEV" ] && cat "$USBDEV/speed" 2>/dev/null || echo -)
DEVNUM=$([ -n "$USBDEV" ] && cat "$USBDEV/devnum" 2>/dev/null || echo -)
MOUNT=$(findmnt -n -o SOURCE,OPTIONS /mnt/ssd 2>/dev/null || echo "NOT MOUNTED")
FSSTATE=$(dumpe2fs -h /dev/sda1 2>/dev/null | awk -F: '/Filesystem state/{gsub(/^ +/,"",$2);print $2}')
FSERR=$(dumpe2fs -h /dev/sda1 2>/dev/null | awk -F: '/FS Error count/{gsub(/^ +/,"",$2);print $2}')
SM=$(timeout 20 smartctl -A -d sat /dev/sda 2>/dev/null)
PC=$(awk '$1=="12"{print $10}'  <<<"$SM"); PR=$(awk '$1=="192"{print $10}' <<<"$SM")
TP=$(awk '$1=="194"{print $10}' <<<"$SM"); RA=$(awk '$1=="5"{print $10}'   <<<"$SM")
PEND=$(awk '$1=="197"{print $10}' <<<"$SM"); UNC=$(awk '$1=="187"{print $10}' <<<"$SM")
# dmesg cross-check: linkwatch samples every 30s, so two drops inside one window count as one
DISC=$(dmesg 2>/dev/null | grep -c "USB disconnect, device number")
FAILS=$(grep -c "FAILED" "$RLOG" 2>/dev/null); FAILS=${FAILS:-0}
RECOV=$(grep -c "recovery complete" "$RLOG" 2>/dev/null); RECOV=${RECOV:-0}

cat <<TXT
=== USB SSD link report $(date -Is) ===
uptime            : $(uptime -p)
port / speed      : $PORT / ${SPEED}M   devnum $DEVNUM
mount /mnt/ssd    : $MOUNT
ext4 sda1         : state=${FSSTATE:-?} fs_error_count=${FSERR:-0}
SMART             : reallocated=${RA:-?} pending=${PEND:-?} uncorrectable=${UNC:-?} temp=${TP:-?}C
SMART power       : power_cycles=${PC:-?} poweroff_retract=${PR:-?}
                    (these move ONLY on real power loss; flat across a drop = data-link fault)
LINK-DROPS        : 1h=$H1  6h=$H6  24h=$H24
current config    : $CFGLINE
dmesg disconnects : $DISC (this boot; >= drop count, linkwatch samples every 30s)
recoveries        : $RECOV succeeded / $FAILS FAILED
--- last 10 drops ---
$(grep "LINK-DROP\|PORT-CHANGE" "$LOG" 2>/dev/null | tail -10)
TXT

if [ "$NOTIFY" -eq 1 ]; then
  if [ "$FAILS" -gt 0 ]; then
    /usr/local/sbin/ha-alert.sh "SSD daily: $FAILS RECOVERY FAILURES logged, $H24 link drops in 24h - needs a human"
  elif [ "$H24" -gt 0 ]; then
    /usr/local/sbin/ha-alert.sh "SSD daily: $H24 link drops in 24h (1h=$H1) on port $PORT, all auto-recovered, fs $FSSTATE"
  fi
  # zero drops -> deliberately silent
fi
exit 0
