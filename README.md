# 在 Raspberry Pi 4 上跟一顆接觸不良的 USB SSD 共存

**繁體中文** · [English](README.en.md)

探針主機只要桌子被晃一下就直接當機。以下是問題的**真正原因**，以及在驗證解法的過程中抓到的三個 bug（其中兩個會讓機器直接死透，而且遠端完全救不回來）。

硬體配備：RPi 4、DietPi on Debian 13，外接 USB SSD 晶片是 **Realtek RTL9210B-CG**（`0bda:9210`），系統 root 檔案系統就裝在那顆 SSD 上。

## 四個問題，只有第一個是明顯的

**1. 把 root 放在可插拔的磁碟上。** USB 接頭瞬間接觸不良，代價應該只是掉一個掛載點，不應該直接搞死整個 kernel。但只要 root 放在 SSD 上，每一次閃斷都是致命的。

**2. 外接盒直接吃了 `uas` 驅動。** 路徑在 `/sys/bus/usb/drivers/uas/2-1:1.0`，而且完全沒有設定任何 quirk。RPi 4 + RTL9210 + UAS 是一組出了名容易卡死（stall）的組合。

**3. USB3 link power management 每次開機都協商失敗：**

```
usb 2-1: enable of device-initiated U1 failed
```

LPM 協商失敗是造成假性離線的經典元凶，而且平常極容易被忽略——因為裝置**看起來還是能用**。

**4. 系統完全沒留下證據，而且這是結構性的問題。** persistent journal 是從 **SSD 上**的目錄 bind mount 過來的，而 `/var/log` 又是只有 50 MB 的 tmpfs（DietPi ramlog）。所以磁碟一斷線，記錄「磁碟斷線」的那份 log 也跟著蒸發。`journalctl --list-boots` 永遠只看得到最後一次開機。當機當了好幾個月，**半筆鑑識資料都沒留下來**。

> 如果你正在追一個偶發性的儲存問題，**第一步務必先確認你的 log 到底寫在哪裡**。在把 log 存放位置搞定之前，其他所有動作都只是在瞎猜。

## 修法

**把角色對調。** root 改回放 SD 卡；SSD 降級成帶有 `nofail` 參數的資料掛載點。

```
# /etc/fstab
PARTUUID=<ssd>  /mnt/ssd  ext4  nofail,noatime,x-systemd.device-timeout=10,x-systemd.mount-timeout=20  0 0
/mnt/ssd/var/lib/<app>  /var/lib/<app>  none  bind,nofail,x-systemd.requires=/mnt/ssd  0 0
```

再加上對應服務的 `RequiresMountsFor=`，這樣它就不可能在掛載點是空的狀態下啟動，然後默默把自己的狀態寫壞。

**設定外接盒 quirks 強化穩定度**，直接寫在 kernel command line：

```
usb-storage.quirks=0bda:9210:u    # IGNORE_UAS -> 強制走 bulk-only transport
usbcore.quirks=0bda:9210:k        # NO_LPM -> 關掉一直協商失敗的 U1/U2
usbcore.autosuspend=-1
```

並且透過 udev 給 SCSI 層足夠的重試空間，避免稍微卡住就直接放棄：

```
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
```

重開後確認生效的訊息：

```
usb 2-1: UAS is ignored for this device, using usb-storage instead
usb-storage 2-1:1.0: Quirks match for vid 0bda pid 9210: 800000
```

此時 `U1 failed` 那行錯誤也不再出現了。唯一代價：關閉 command queuing 之後，循序讀取掉到約 153 MB/s。對純資料碟來說這個交換非常划算，而且讀寫依然是 SD 卡的好幾倍。

> **操作順序很重要。** USB quirks 一定要等 root 已經完全搬離 SSD 之後才能套用。萬一 bulk-only transport 剛好搞垮你那顆外接盒，而 root 還在上面，機器就會直接開不起來——而你人可能不在現場。

## 三個「真的動手測才會發現」的 bug

這些問題在你真的手動把硬碟拔掉之前都不會現形。我們可以直接在 bus 層模擬斷線與重連：

```
echo 2-1 > /sys/bus/usb/drivers/usb/unbind    # 拔
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # 插回去
```

**Bug 1——晶片重新插拔後自己醒不過來。** rebind 之後系統雖然看得到它（`lsusb` 有抓到、`usb-storage` 有掛上、SCSI host 有建立），但 `/dev` 底下**永遠長不出 block device**。dmesg 會一直卡在：

```
usb 2-1: reset SuperSpeed USB device number 2 using xhci_hcd
```

手動對 SCSI host 做 rescan（`echo "- - -" > /sys/class/scsi_host/host0/scan`）**完全沒有用**。真正有效、而且每次試都能一發成功救回來的是：

```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 4
echo 1 > /sys/bus/usb/devices/2-1/authorized
```

取消授權會強迫系統做一次**真正的重新列舉**，徹底跳出卡在半初始化的 reset 迴圈。這是這份文件裡含金量最高的一招。

**Bug 2——udev 規則永遠等不到觸發。** 直覺上最容易想到的觸發條件是 block device：

```udev
ACTION=="add", KERNEL=="sda1", ...        # 錯的
```

但 `sda1` 正是復原腳本**要想辦法生出來的目標**。這就陷入了雞生蛋蛋生雞的死胡同：規則永遠在等它自己該產生的東西。所以觸發條件必須改綁在 USB 橋接器上——而且除了 `add` 之外還要匹配 `bind`，因為 driver 層做 rebind 時發出的事件是 `bind`：

```udev
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="9210", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ssd-recover.service"
```

**Bug 3——systemd 的啟動速率限制，偏偏在最需要的時候扯後腿。** 預設是 10 秒內最多 5 次。接觸不良產生的連續抖動會在一瞬間衝破這個上限，導致 systemd 直接**罷工拒絕**再次啟動復原 unit。解法是設定 `StartLimitIntervalSec=0` 拔掉上限，並且在腳本內拿 `flock -n` 鎖定，讓重疊觸發的行程自動讓路退出，而不是一起搶著處理同一顆裝置。

## 復原階梯

完整的復原邏輯寫在 [`scripts/ssd-recover.sh`](scripts/ssd-recover.sh)，由 udev 觸發，並掛一個 60 秒的 backstop timer 當兜底保護：

1. 快速路徑——如果硬碟本來就正常掛載且可寫入，直接退出什麼都不做。
2. 裝置已消失但掛載點還卡著 → 先停掉唯一持有 handle 的那個服務，再執行 `umount -l`。
   **千萬不要**手癢打 `fuser -k -m`，那會把 Docker 和其他所有服務無差別一起殺光。
3. 最多重試 4 輪：SCSI rescan → `authorized` toggle → `usb-storage` unbind/rebind。
4. 重新掛載，然後**實測寫入確認沒有被掛成唯讀**。只有在這一步失敗時才去跑 `e2fsck -p`；
   回傳值 ≥ 2 就直接放棄掛載並發出警報。**絕對不對正常的硬碟隨便自動 fsck，也絕不在半連線狀態下憑感覺盲目 fsck。**
5. 重新建立資料目錄的 bind mount，重啟相依的服務。

實際從一次真實斷線量到的結果，全程無人介入：

```
20:07:20  --- trigger=udev ---
20:07:26  authorized toggle on /sys/bus/usb/devices/2-1
20:07:42  sda1 present after 1 attempt(s)
20:07:42  mounted /mnt/ssd rw -> service restarted -> recovery complete
```

總共只要 22 秒。而且在整個斷線期間，主系統穩如泰山：SD 卡上的 root 始終可寫，Docker、Home Assistant、Tailscale、SSH 與探針全部活得好好的；systemd 乾淨俐落地卸載了那顆死掉的硬碟、沒有殘留殭屍掛載，資料服務也自己停了下來，而不是對著一個空目錄繼續亂寫。

## 當軟體解法不再管用，證明到底是「哪一層」壞了

兩週後，同一台主機又開始掉硬碟——這一次 root 已經安全地待在 SD 卡上、上述所有 quirk 都已確認生效，而且硬碟完全處於閒置狀態。警報寫著「I/O error delta 12」。但這個數字只告訴你有東西壞了，對於「到底是什麼壞了」隻字未提。

真正能一錘定音的特徵就在 `dmesg` 裡：

```
usb 2-1: USB disconnect, device number 6
usb 2-1: new SuperSpeed USB device number 7 using xhci_hcd   <- 0.3 s later
```

**先 disconnect 隨後又重新列舉**既不是 command timeout、不是 UAS，也不是 link-power-management 失敗。上述任何一種狀況都不會讓裝置脫離（detach）。這是實體路徑上的某個環節——接頭、線材，或是橋接器本身——真正中斷了連線。沒有任何 kernel 參數救得了這種問題，別再白費力氣找了。

但這依然剩下兩種截然不同的實體故障，而且需要更換的零件完全不同：

|  | 硬碟失去 5 V 供電 | 資料連線中斷，硬碟保持供電 |
|---|---|---|
| 元凶 | 電源接點、線材阻抗、主機供電上限 | SuperSpeed 訊號線：接頭磨損、線材品質、橋接器 |
| 解法 | 帶外接電源的 Hub、更短／更粗的線材 | 重新插拔、換插別的 port、改走 USB 2.0、換新外接盒 |

**SMART 能直接免費告訴你答案。**屬性 `12 Power_Cycle_Count` 與 `192 Power-Off_Retract_Count` 只有在硬碟真正斷電時數值才會增加。在每次斷線發生的瞬間去取樣：

```
smartctl -A -d sat /dev/sda | awk '$1==12||$1==192||$1==194'
```

在這台機器發生的十次斷線中，這兩個計數器的數值**完全沒變**——而當天晚上兩次刻意手動拔除實體線路的測試中，`Power_Cycle_Count` 確實從 **2867 → 2869** 往前推進。計數器運作正常；那些斷線單純就只是從未斷過電。診斷結論：問題出在 SuperSpeed 訊號完整性（signal integrity），而不是供電軌（power rail）。

這也決定了各種解法的優先順序。換插另一個 USB3 port 值得試一次，因為它改變了接頭接觸面，但它依然走同一個控制器與同一條線。**改插 USB 2.0 port 才是真正拉高處置層級的手段**：USB2 完全不走 SuperSpeed 訊號線，而且傳輸速率是 480 Mb/s 而不是 5 Gb/s，因此訊號容限（signal margin）直接大了好幾個數量級。你用 ~150 MB/s 換來 ~40 MB/s。對存放媒體或備份的磁碟區來說，這個交換非常划算——在我們這裡，它只不過把每週一次 20 GB 的備份時間從 3 minutes 變成 10。如果連 USB2 都照樣斷線，那就是外接盒死透了；直接換掉吧。

關於 `-d sat` 有個小提醒：RTL9210B 同時支援 NVMe 與 SATA 硬碟，而 smartmontools 預設會猜背後是 NVMe。如果 `-d sntrealtek`、`-d sntasmedia` 與 `-d auto` 全部失敗並跳出 `unsupported scsi opcode`，就表示橋接器後面接的是一條 **SATA** M.2，這時候只有 `-d sat` 才能正常運作。

### 沒錯，那些寫入真的遺失了

`Buffer I/O error on dev sda1 ... lost async page write` 代表寫入是**直接被丟棄，而不是重試**，而且每一次斷線也都會伴隨 `Aborting journal` 與 `JBD2: I/O error when updating journal superblock`。這次之所以能全身而退，純粹只是因為磁碟區當時處於閒置狀態：每一個遺失的 block 都是 ext4 metadata，所以在下一次掛載時由 `EXT4-fs (sda1): recovery complete` 成功重放（replay），`dumpe2fs -h` 也依然回報 `state: clean` 與 `FS Error count 0`。

千萬別把這當成沒事。在真實的寫入負載下，`data=ordered` 會在背後默默遺失傳輸中的 *data* page——而 journal replay 根本不可能把這些資料救回來。一顆每 90 seconds 就重新列舉一次的硬碟不是什麼「自我修復」，它只是運氣好，還沒被要求寫入任何重要資料而已。

## 已經修好的故障，就別發警報吵人了

上面那套復原階梯實測成功了 17 times out of 17。但每一次成功復原都會往手機發送推播通知，因為健康檢查是在針對「症狀計數器（*symptom counter*）」發出警報，而不是看「最終結果」。一整晚不斷收到「I/O error delta 12 (warning 1/3)」這類推播，只會訓練維運者隨手把它們滑掉——而真正要命的那條通知，往往就是這樣被漏掉的。

經歷過真實事故考驗後留下來的原則：

- **復原成功 → 寫入 log，不要發通知。** 既然修好了，這就是一件無關緊要的事件（non-event）。
- **復原失敗 → 立即通知**，而且要說清楚目前還有什麼正常運作。「系統沒事、root 在 SD 上、qbittorrent 維持關閉」是有意義、可採取行動的資訊；「I/O error delta 12」根本毫無幫助。
- **看頻率，而非單一事件 → 只發一次通知。** 一小時內斷線三次，意味著硬體快死透了，就算每一次都成功修復也一樣。將通知上限限制在每小時最多一則。
- **每日摘要在平安無事時保持沉默。** 沒什麼好回報才是最常見的狀況，定時發送「一切安好」的訊息只會訓練人學會無視你。

[`scripts/ssd-linkwatch.sh`](scripts/ssd-linkwatch.sh) 實作了斷線次數統計與頻率警報；[`scripts/ssd-report.sh`](scripts/ssd-report.sh) 則負責即時查詢與每日摘要。兩者都把資料寫在 **SD 卡**上，這樣即使受診斷的硬碟斷線消失，證據也依然能完整保留下來。

## 差點默默搞垮這一切的寫死 port 路徑

上面提到的所有操作都指涉到了 `/sys/bus/usb/devices/2-1`——包括唯一能真正救回這顆橋接器的 `authorized` 切換（toggle），以及 `2-1:1.0` 的 usb-storage rebind。這個路徑對應的是**實體連接埠**（physical port）。只要把插頭換插到隔壁插孔，路徑就會變成 `2-2`，換到 USB2 連接埠則會變成 `1-1.3`，這時整套復原階梯就會默默失去任何復原能力。系統完全不會報錯；它只是從此再也救不回任何東西。

改用 Vendor ID 與 Product ID 來動態解析裝置路徑：

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

既然都處理到這裡了，順便把整個系統的其他設定也全面盤查一遍同類型的 bug 是很值得的。在我們這裡，udev 規則本來就綁定 `idVendor`/`idProduct`、`fstab` 使用 `PARTUUID`，而 `cmdline.txt` 裡的 kernel quirks 也是指定 `0bda:9210`——全部都與 port 無關（port-independent）。當初只有那兩支腳本寫死了插孔路徑——而這種事情平時完全隱形，直到哪天你為了排除其他問題換插了線，才會無聲無息地踩雷。

## 另外兩件值得抄走的事

**沒實測驗證過的 watchdog 等於沒有 watchdog。** BCM2835 硬體 watchdog 上限是 15 秒（可以用 `cat /sys/class/watchdog/watchdog0/timeout` 驗證）。你要求 10 秒，systemd 會回報 15 秒；你要求 30 秒，硬體底層默默還是只給你 15 秒。請務必照真實的硬體上限規劃。

**任何由機器自己發出的警報，都會跟著機器一起陪葬。** 只要通知是透過跑在**那台機器本機**上的服務送出，遇到斷電、記憶卡掛掉、kernel 卡死這些狀況，你絕對收不到任何通知。必須在外部加一個 heartbeat，讓「**機器沒聲音**」這件事本身直接成為警報。[`cf-heartbeat/`](https://github.com/Hydr0neFN/hinet-dual-path-probe/tree/main/cf-heartbeat) 就是做這件事的一個輕量 Cloudflare Worker：用 KV 記錄 last-seen、Cron Trigger 負責察覺沉默、Email Routing 負責發信。
