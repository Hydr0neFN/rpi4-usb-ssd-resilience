# unit 檔與 udev 規則

**繁體中文** · [English](README.en.md)

這裡收錄的是直接從跑這套儲存韌性機制的那台機器上抓下來的**實際配置檔案**。因為每個檔案在 Linux 系統中的安裝路徑各不相同，在此統一攤平放在同一個目錄。請參考下表將檔案複製到對應位置，並執行 `systemctl daemon-reload`。

| 檔名 | 安裝到 |
|---|---|
| `ssd-recover.service` / `ssd-recover.timer` | `/etc/systemd/system/`——USB 磁碟復原與 60 秒 backstop |
| `98-rtl9210-recover.rules` | `/etc/udev/rules.d/`——橋接器一列舉就觸發復原 |
| `99-rtl9210-timeout.rules` | `/etc/udev/rules.d/`——給這顆橋接器較長的 SCSI timeout |
| `systemd-system.conf.d-10-watchdog.conf` | `/etc/systemd/system.conf.d/10-watchdog.conf` |

## 啟用之前務必確認

- **udev 規則寫死了 `0bda:9210`**（Realtek RTL9210）。請改成你自己橋接器的 ID，或者如果你的碟不是 USB 就直接刪掉這兩條規則。
- `ssd-recover.sh` 與 `root-backup.sh` 會呼叫 `/usr/local/sbin/ha-alert.sh`（Home Assistant 通知）與 `/usr/local/sbin/io-health.sh`（SMART / dmesg 檢查）。這兩支是主機專屬的，**沒有包含在 repo 裡**。`ha-alert.sh` 有 `[ -x ]` 保護，不存在就自動跳過；**`io-health.sh` 沒有**——你得自己補一支，或是在使用 `root-backup.sh` 之前把那一行刪掉。
- `root-backup.sh` 假設的佈局寫在 [`../README.md`](../README.md)：root 在 SD 卡、USB 碟以 `nofail` 掛在 `/mnt/ssd`。不符合就會拒絕執行，但跑之前務必先看過腳本——它用的是 `rsync --delete`，而目的地上同時放著活資料。
- `root-backup.sh` 會取用 `flock /run/ssd-recover.lock`，避免 60 秒的復原 timer 在 rsync 中途把碟卸載掉。

## 安裝後的檢查

```sh
systemctl status ssd-recover.timer
udevadm test /sys/bus/usb/devices/2-1 2>&1 | grep -i ssd-recover
findmnt /mnt/ssd
tail -5 /var/lib/ssd-recover.log
```

**`ssd-recover.timer` 狀態為 active (waiting)、`findmnt` 能看到 `/mnt/ssd` 掛載** → 正常運作。
**`findmnt` 找不到掛載點或 `udevadm` 沒有匹配到規則** → 規則未生效或 USB 裝置路徑與 ID 不符，請確認 `/sys/bus/usb/devices/` 下的實際拓撲。
