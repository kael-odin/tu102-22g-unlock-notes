# 01 · 逐步复现

从一台原厂状态的 TU102 22G 卡，到屏幕打出 `*** UNLOCKED ***`，再到基准数字落地。本文按**实际执行顺序**记录，所有日志片段都来自本机真实输出（仅删掉重复行）。

> 动手之前请先读 [README 的「固件红线」](../README.md#固件红线请先读这段再-fork)：本仓不含固件，你也不能把构建产物贴给别人。

---

## 0. 判断你的卡能不能走这条路

四个条件，缺一不可：

| 条件 | 怎么查 | 不满足会怎样 |
|---|---|---|
| 是 TU102（2080 Ti / Titan RTX / 同代 CMP） | `nvidia-smi --query-gpu=name --format=csv` 或 GPU-Z | 其它架构没有 `0x409664` 这组寄存器 |
| 是 **22 GiB** 改装卡 | GPU-Z 看显存；程序内看 `capacity` | 11 GiB 卡在 `capacity=0x2c9` 守卫处直接退出（**只读拦截，不会写坏**） |
| PCI ID 已知 | 设备管理器 → 硬件 ID | 默认只认 `1E04/1E09` 等；本卡 `1E07` 见 [patch](../patches/tu102-1e07-0b-family.patch) |
| 主板支持关 Secure Boot + 开 Above 4G | BIOS | Secure Boot 开着就跑不了未签名 EFI；Above 4G 关着分配不到高位显存 |

`capacity` 的判据是寄存器 `0x100ce0` 读到 `0x2c9`：

```
[TU102] capacity=0x000002c9 OK (22GiB identity confirmed)
```

同一个寄存器在 11 GiB 卡上读到别的值，程序打印 `BAD capacity` 后停下——这是整条链里最早的一道保险。

---

## 1. 准备两个环境

### 1.1 Linux 侧（构建）

本机用 **WSL2 Ubuntu 24.04**。需要 `build-essential` 与 `gnu-efi`：

```bash
sudo apt update && sudo apt install -y build-essential gnu-efi
```

> 如果 `apt` 卡在 `Connecting...` 或 DNS 错误，是代理/TUN 把 WSL 的出网打断了。见 [03-pitfalls.md](03-pitfalls.md#2-wsl2-里的-apt-连不上clash-tun)，绕法是 Windows 侧下载 `.deb` 再 `dpkg -i`。

### 1.2 Windows 侧（做 U 盘 / 改注册表）

只需要 PowerShell 5.1（系统自带）。**本仓所有 `.ps1` 都是纯 ASCII**，原因见 [03-pitfalls.md](03-pitfalls.md#1-中文-ps1-在-ps-51-里直接解析失败)。

### 1.3 移植仓库

本仓是「记录 + 补丁」，代码本体在上游：

```bash
git clone https://github.com/chenxluo/tu102-22g-uefi-unlock
cd tu102-22g-uefi-unlock
git apply /path/to/tu102-22g-unlock-notes/patches/tu102-1e07-0b-family.patch
```

补丁只改两处：设备 ID `0x1E04 → 0x1E07`，以及 10 个几何常量。**不含任何固件字节。**

---

## 2. BIOS 设置

重启进 BIOS，只改两项：

- **Above 4G Decoding = Enabled**（有的板子叫 "4G Above Decoding" / "Above 4G MMIO BIOS assignment"）
- **Secure Boot = Disabled**（若该项灰掉，先把 "OS Type" 改成 "Other OS"）

安全启动关掉之后，机器可以执行任意未签名的 UEFI 应用——这正是本方案能成立的前提，也是它唯一真正的攻击面。**只在你自己拥有、并且清楚后果的机器上这么做。**

B760M 这类板子没有 "Fast Boot" 选项是正常的，不影响流程。

---

## 3. 阶段 0 · 只读转储（不需要任何固件）

这一步的目标只有一个：**拿到你自己卡里的 FWSEC 和它的几何描述**。它不写卡、不需要 blob、失败也不会留下痕迹。

### 3.1 构建 dump 版

```bash
cd tu102-22g-uefi-unlock/efi-unlock-tu102
DUMP_ONLY=1 ./build.sh
# => TU102DUMP.EFI
```

`DUMP_ONLY=1` 会把 4 个 blob 的符号替换成占位实现，因此**这个阶段你一个 NVIDIA 固件都不需要**。

### 3.2 装到 U 盘

```powershell
# 管理员 PowerShell
cd D:\Github-Star\tu102-22g-unlock-notes
.\tools\make-usb-ascii.ps1 -DriveLetter G -Image <移植仓库>\efi-unlock-tu102\TU102DUMP.EFI
```

脚本会：校验目标是 USB 且不是系统盘 → `Clear-Disk` → 建 MBR + 1 GB FAT32 活动分区 → 把 EFI 放成 `\EFI\Boot\BOOTX64.EFI` → 预置两个 1 MiB 占位文件。

> 它会**清空整块 U 盘**，且不会二次确认。双重拒绝（BusType 必须是 USB、不能是系统盘）是唯一保险，别用错盘符。

### 3.3 引导并转储

重启 → BIOS 里选 U 盘（或开机按 F8/F11 弹启动菜单）→ 选中后屏幕会短暂黑屏，然后出现文字。

真实日志（`local-dump/50hx_log.txt`）：

```
[TU102 f] fast hit enc=2 01:00.0 id=0x1e0710de
[40HX bar] cmd=0x00100003 BAR0=0x60000000 gBar0Base=0x60000000 (enc=2)
[TU102] capacity=0x000002c9 OK (22GiB identity confirmed)
[50HX] using default geometry fbSize=0x580000000 (WPR2_LO=0x1ffffe00)
[v55 boot]: PLM=0xffffff8f SS0=0x00002001 SS1=0x00000006 GFW=0x000003ff WPR2lo=0x1ffffe00
[TU102] DUMP-ONLY build  stopping before any mutation
[TU102] BOOT0=0x162000a1 capacity=0x000002c9 (expect 0x2c9=22GiB) workspace=0x00000001 (expect 1)
[dump] reading 1MB from BAR0+0x300000 (bar=0x60000000)...
[dump] \tu102_prom_300000.bin head=55aa76eb (55aa=PCI-ROM ok)
[dump] 1MB OK via SFS -> \tu102_prom_300000.bin
[dump] reading 1MB from BAR0+0x11000 (bar=0x60000000)...
[dump] \tu102_prom_011000.bin head=0001d0ba (55aa=PCI-ROM ok)
[dump] 1MB OK via SFS -> \tu102_prom_011000.bin
```

逐行读：

- `capacity=0x000002c9` —— 22 GiB 身份成立。
- `BOOT0=0x162000a1` —— 架构字段 `0x16` = TU10x，FECS 引导向量对得上。
- `workspace=0x00000001` —— 上游要求的前置状态，读不到 1 就不要往下走。
- `head=55aa76eb` —— `55aa` 是 PCI ROM 魔数，说明这个偏移真是 VBIOS 起点，不是乱码。
- 两个 1 MiB 窗口：`+0x300000` 是主 ROM（**关键**），`+0x11000` 是另一段（备用，本次未用）。

`PLM=0xffffff8f` / `SS0=0x00002001` 是**锁定态基线**，记下来，等下要对比。

> 屏幕上会有 `PAUSE 20 s - DUMP RESULTS - photograph this screen`。这是给拍照留证据的，转储文件已经写进 U 盘了。

### 3.4 收文件

引导结束后程序会自己链式加载 `bootmgfw.efi` 进 Windows——**不用管它成功没成功**，你只要在 U 盘根目录拿到：

```
tu102_prom_300000.bin    1 MiB
tu102_prom_011000.bin    1 MiB
50hx_log.txt             本次日志
```

（占位文件 `tu102p30.bin` / `tu102p11.bin` 是预分配用的，可以忽略。）

---

## 4. 阶段 1 · 标定

把 `tu102_prom_300000.bin` 拖到 Linux 侧，按 **[02-fwsec-calibration.md](02-fwsec-calibration.md)** 解析出 FWSEC blob 与 10 个常量。

产出物长这样（`fwsec_50hx_desc.json`）：

```json
{
  "prod": {
    "rom_desc_offset": "0x3f200",
    "StoredSize": "0x9a10",
    "InterfaceOffset": "0xdc",
    "IMEMLoadSize": "0x9600",
    "IMEMSecBase": "0x300",
    "IMEMSecSize": "0x9300",
    "DMEMOffset": "0x9600",
    "DMEMLoadSize": "0x410",
    "blob_size": 39440,
    "blob_sha256": "1516eb68…"
  }
}
```

---

## 5. 阶段 2 · 构建解锁版

### 5.1 取公共 blob

```bash
cd tu102-22g-uefi-unlock
./<notes>/tools/get-blobs.sh ./efi-unlock-tu102
# 四个文件逐个校验 SHA-256，任一不符即删掉并报错
```

### 5.2 放你自己的 FWSEC

```bash
cp local-dump/fwsec_50hx_prod.bin efi-unlock-tu102/blobs/fwsec_native.bin
sha256sum efi-unlock-tu102/blobs/fwsec_native.bin
# 必须等于你在阶段 1 算出来的哈希
```

### 5.3 编译

```bash
cd efi-unlock-tu102
TU102_ALLOW_FWSEC=1 ./build.sh
# => TU102UNLK.EFI
```

`TU102_ALLOW_FWSEC=1` 的作用：构建脚本里写死了参照卡的 FWSEC 哈希（`c6fa28fa…`），你换了固件家族必然对不上，这个开关是显式承认"我知道我在用非参照固件"。

> ⚠️ **构建后的第一行 banner 仍然会打印 `native FWSEC c6fa28fa`** —— 那是一句没跟着改的硬编码文案，实际嵌进镜像的是你放进去的那个 blob。**用 `sha256sum signatures` 或解包比对确认，不要相信 banner。** 详见 [03-pitfalls.md](03-pitfalls.md#6-banner-谎报-fwsec-哈希)。

### 5.4 装 U 盘

```powershell
.\tools\make-usb-ascii.ps1 -DriveLetter G -Image <移植仓库>\efi-unlock-tu102\TU102UNLK.EFI
```

---

## 6. 阶段 3 · 让驱动接受解锁态

```powershell
# 管理员 PowerShell
.\tools\gsp-mode-ascii.ps1 on
# instance 0000 desc=NVIDIA GeForce RTX 2080 Ti EnableGpuFirmware= -> 1
```

这个脚本只改**匹配 `VEN_10DE&DEV_1E07` 的那个驱动实例**的 `EnableGpuFirmware` DWORD（`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-…}\<instance>`），不碰显卡本身。

不做这一步会怎样：解锁引导照常成功，但进 Windows 后设备管理器报 **Code 43**；再正常重启一次就恢复，不会坏。

回滚：

```powershell
.\tools\gsp-mode-ascii.ps1 off
```

---

## 7. 阶段 4 · 解锁引导

重启 → 选 U 盘 → 等屏幕输出。真实日志（`usb-backup/50hx_log.txt`，删去了逐寄存器探针的重复段）：

```
[TU102] capacity=0x000002c9 OK (22GiB identity confirmed)
[50HX] BOOT0=0x162000a1 (expect arch 0x16<<24 = TU10x)
[v55 boot]: PLM=0xffffff8f SS0=0x00002001 SS1=0x00000006 GFW=0x000003ff WPR2lo=0x1ffffe00
probe: SS0=0x00002001 SS1=0x00000006 after writing 0x88888888/0x8
    ^ 直接写寄存器是无效的：必须走 FECS 引导路径

[50HX fwsec50] native blob @0x11982c000 (0x9a10 B, this card's FWSEC)
fwsec50: data iface@0xdc hdr={1,4,8,2} mapper@0x380 sig=0x50414d44 ver=20545 cmd_in_off=0x3d0 size=0x40
fwsec50: *** WPR2 UP lo=0x057fe000 hi=0x057fee00 after 0ms ***

--- tu102 attempt 1/2: no-reset (driver-style) ---
tu102: rb IMEM[0]=0xce100049(exp 0xce100049) IMEM_S[0x100]=0xdead5ec1 DMEM[0x200]=0x67436032(exp sig 0x67436032)
tu102: BOOTVEC=0, mailbox0=0x1882b000 mailbox1=0x00000001, STARTCPU...
tu102: started; hold 3s WITHOUT reg reads (v57 lesson)
tu102:   cpu=0x10   irq=0x10   dbg=0xdeadb00d   m0=0x0 m1=0x1
tu102: RESULT: PLM=0xffffff8f SS0=0x88888888 SS1=0x00000008
tu102: *** mbox0=0 — booter OK (attempt 1) ***

[50HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
[rebar] no 16 GiB-aligned span in window — skip
```

### 判据只有一行

```
[50HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
```

其它看起来像"失败"的输出都是正常的：

| 输出 | 含义 |
|---|---|
| `PLM=0xffffff8f` | PLM 的读值就是这样，`0x8f` 是"已开放"的形态 |
| `WARN dst!=0xfd00` | BL 落点与 BOOTVEC 不同，上游已知且无害 |
| `[rebar] no 16 GiB-aligned span — skip` | 本机 BAR 窗口不够大，跳过重定 BAR；不影响解锁 |
| `[gen2] not attempted pre-OS` | Gen2 只在 OS 侧做（上游 issue #25） |
| `trace[..]=0`、`dbg=0xdeadb00d` | 诊断残留，非错误码 |

### 拔 U 盘

链载 `bootmgfw.efi` 之后，Windows 的启动管理器已经把需要的东西读进内存了。**Windows 桌面出现后可以拔 U 盘**，解锁状态不受影响（它在 GPU 寄存器里，不在 U 盘上）。下次要解锁，插回去重启即可。

---

## 8. 阶段 5 · 验证

```powershell
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
# NVIDIA GeForce RTX 2080 Ti, 22528 MiB, 617.42
```

```bash
python bench/bench_gemm.py bench/results.json
```

本机输出（`bench/results-2080ti-22g-1e07.json`）：

```
FP16  2048^3:     0.22 ms    79.97 TFLOPS
FP16  3072^3:     0.77 ms    75.27 TFLOPS
FP16  4096^3:     1.43 ms    95.87 TFLOPS
FP32  2048^3:     1.28 ms    13.40 TFLOPS (control)
```

**怎么判断"真的解锁了"而不是"机器变快了"**：

1. FP32 对照应落在 13.4 TFLOPS 附近（2080 Ti 的规格就是 13.45）——它不动，说明没有超频。
2. FP16 4096³ 应在 90 TFLOPS 量级；锁定态的上界是 53.8（半速），**不可能**自然跑到 90+。
3. 重启一次、不插 U 盘再测，应回到 50 左右。

---

## 9. 回滚与日常状态

| 目标 | 操作 |
|---|---|
| 这次开机不要解锁 | 正常开机，不插 U 盘 |
| 永久回到原厂 | `gsp-mode-ascii.ps1 off`（删注册表项），重启 |
| 恢复 BIOS | Above 4G / Secure Boot 按原值改回 |
| 擦掉 U 盘 | 格式化即可，里面没有任何密钥或固件（EFI 里有，格式化即消失） |

没有需要"卸载"的东西，也没有写入 VBIOS：**这条路线在磁盘上只留下一个 DWORD 和一个 U 盘文件。**

---

## 10. 一次完整流程的时间成本（本机实测）

| 阶段 | 耗时 | 备注 |
|---|---|---|
| 装 WSL 依赖 | 5–15 min | 取决于网络 |
| 构建 dump 版 | < 10 s | |
| 做 U 盘 | < 1 min | 取决于 U 盘速度 |
| 转储一次引导 | ~3 min | 含两次 20 s 拍照暂停 |
| 标定 | 20–40 min | 第一次做，之后换卡 10 min |
| 构建 unlock 版 | < 30 s | |
| 解锁引导 | ~2 min | |
| 基准 | ~1 min | |

真正需要人在屏幕前操作的只有两次重启和两次选启动项。
