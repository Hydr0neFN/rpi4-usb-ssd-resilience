#!/bin/bash
# Print the sysfs path of the RTL9210B bridge, wherever it is plugged in.
# Hardcoding 2-1 was fine while the enclosure lived on a USB3 port; moving it to a
# USB2 port makes it 1-1.x and every hardcoded path silently stops working -- including
# the authorized-toggle, which is the ONLY recovery step that actually revives this bridge.
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "0bda" ] || continue
  [ "$(cat "$d/idProduct" 2>/dev/null)" = "9210" ] || continue
  echo "$d"
  exit 0
done
exit 1
