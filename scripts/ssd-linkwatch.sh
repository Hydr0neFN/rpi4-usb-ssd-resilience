#!/bin/bash
# Watches the RTL9210 USB link. Two jobs:
#   drop accounting: when the USB device number changes the link re-enumerated.
#      Record SMART power-cycle counters at that moment -- if they advance, the
#      DRIVE lost power (cable/5V rail); if they do not, only the USB link broke
#      (signal integrity / bridge).
LOG=/var/lib/ssd-linkwatch.log
STATE=/run/ssd-linkwatch.devnum
ALERTED=/run/ssd-linkwatch.alerted
USBDEV=$(/usr/local/sbin/usbdev-rtl9210.sh 2>/dev/null || echo /sys/bus/usb/devices/2-1)
ts() { date -Is; }

# bound the log the same way ssd-recover.sh does -- this box runs unattended
if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$LOG" > "$LOG.trim" && mv "$LOG.trim" "$LOG"
fi

[ -e "$USBDEV/devnum" ] || { echo "$(ts) bridge absent" >> "$LOG"; exit 0; }
NOW=$(cat "$USBDEV/devnum")
PREV=""
[ -f "$STATE" ] && PREV=$(cat "$STATE")
echo "$NOW" > "$STATE"

if [ -n "$PREV" ] && [ "$PREV" != "$NOW" ]; then
  SM=$(timeout 20 smartctl -A -d sat /dev/sda 2>/dev/null)
  PC=$(awk '$1=="12"{print $10}' <<<"$SM")
  PR=$(awk '$1=="192"{print $10}' <<<"$SM")
  TP=$(awk '$1=="194"{print $10}' <<<"$SM")
  echo "$(ts) LINK-DROP $(basename "$USBDEV") devnum $PREV -> $NOW | power_cycles=${PC:-?} poweroff_retract=${PR:-?} temp=${TP:-?}C" >> "$LOG"

  # alert if 3+ drops in the trailing hour, at most once per hour
  SINCE=$(date -d '1 hour ago' -Is)
  N=$(awk -v s="$SINCE" '$2=="LINK-DROP" && $1 > s' "$LOG" | wc -l)
  if [ "$N" -ge 3 ]; then
    LAST=0; [ -f "$ALERTED" ] && LAST=$(cat "$ALERTED")
    if [ $(( $(date +%s) - LAST )) -ge 3600 ]; then
      date +%s > "$ALERTED"
      /usr/local/sbin/ha-alert.sh "SSD USB link dropped $N times in the last hour - bridge/cable is failing, data survived"
    fi
  fi
fi

# No keep-alive: ssd-recover.sh's fast path already touches /mnt/ssd every 60s, so the
# bridge is never idle long enough to sleep. Adding traffic here would only confound the
# drop-rate measurement.
exit 0
