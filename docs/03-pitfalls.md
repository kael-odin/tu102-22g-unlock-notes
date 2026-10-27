# 03 · 坑位与排错

按"会让人卡住多久"排序。每条都给出**现象 → 原因 → 处置**，尽量引原文日志。

---

## 1. 中文 `.ps1` 在 PS 5.1 里直接解析失败

**现象**

```
At line:1 char:3
+ 除?
+   ~
Unexpected token '除?' in expression or statement.
```

或者报一堆乱码后 `Missing closing '}'`。

**原因**：Windows PowerShell 5.1 读无 BOM 的 UTF-8 文件时**按 GBK 解释**，中文注释会把后面的引号、括号一起吃掉。PowerShell 7 没这个问题，但系统默认的是 5.1。

**处置**：所有脚本写成**纯 ASCII**（注释、字符串全英文）。本仓 `tools/*.ps1` 都是这样来的。不要试图"另存为 UTF-8 with BOM"——BOM 在部分 `-File` 调用链里又会引出新问题，ASCII 是一劳永逸的。

---

## 2. WSL2 里的 `apt` 连不上（Clash TUN）

**现象**

```bash
$ sudo apt update
Ign:1 http://archive.ubuntu.com/ubuntu noble InRelease
Err:1 ... Temporary failure resolving 'archive.ubuntu.com'
```

或一直卡在 `Connecting to ...`。

**原因**：Windows 侧 Clash 开 TUN 模式时，WSL2 的虚拟网卡出网路径被打断（WSL 的 DNS 走 `/etc/resolv.conf` 里那个虚拟网关，而 TUN 把 UDP 53 吃掉了）。

**处置**（三选一，从轻到重）：

1. Windows 侧先把 Clash 切到"系统代理 + 关 TUN"，装完再切回来；
2. Windows 上下载 `.deb`，拷进 WSL 再 `sudo dpkg -i`：

   ```powershell
   curl.exe -L -o $env:TEMP\gnu-efi.deb http://archive.ubuntu.com/ubuntu/pool/main/g/gnu-efi/gnu-efi_3.0.17-1_amd64.deb
   ```

   ```bash
   cp /mnt/c/Users/<you>/AppData/Local/Temp/gnu-efi.deb /tmp/
   sudo dpkg -i /tmp/gnu-efi.deb
   ```

3. 不开 WSL，直接用 Docker 里的 Ubuntu 镜像编（`gnu-efi` 同样要装）。

> 别去改 WSL 的 `resolv.conf` 或 `nameserver 8.8.8.8`——TUN 模式下流量根本出不去，改了也没用。

---

## 3. 链载 Windows 失败：`0xE`（NOT_FOUND）与三级退路

**现象**：解锁已经成功，但屏幕停在黑底白字，最后一行类似

```
[chain] StartImage -> 800000000000000e
```

`0x800000000000000e` 就是 `EFI_NOT_FOUND`。屏幕上没有任何报错，只有这串十六进制。

**原因**：EFI 应用要去加载 `\EFI\Microsoft\Boot\bootmgfw.efi`，但**它跑的这一刻，U 盘文件系统服务（SFS）指向的是 U 盘**。用 `LoadImage` + 纯路径名去找 Windows 的 ESP 是找不到的——路径名相对于当前设备。

本机日志里能看到完整的三级尝试：

```
[chain] LoadImage(\EFI\Microsoft\Boot\bootmgfw.efi) -> 800000000000000e
[chain] dp-by-startLBA 2048 -> loadfile -> 800000000000000e
[chain] GPT partition dp HD(1,GPT,18C41068-71F9-434E-AB40-CF3FF33A6626) -> StartImage OK
```

**处置**：

- 第 1、2 次失败是**设计好的退路**，不要当 bug；
- 第 3 次成功靠的是 `LocateDevicePath` 拿到 GPT 分区节点，再用 `LoadImage(DevicePath)` 加载——这是唯一稳的做法；
- 如果第 3 次也失败，通常是 **ESP 不在 GPT 磁盘上**（老 MBR 安装）或 **Windows 装在第二块盘且其 GPT 分区没被枚举到**。此时：
  - 进 BIOS 确认那块盘是可见的、没被设成 RAID/隐藏；
  - 或者直接拔掉 U 盘重启——**解锁状态已经写进 GPU 寄存器了，不需要再链载**。链载只是为了"不重启直接进系统"的便利。

> 关键认知：**链载失败 ≠ 解锁失败**。判断解锁只看 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***` 那一行。

---

## 4. `PLM=0xffffff8f` 看着像没开放

**现象**：解锁成功后，日志里仍然是

```
tu102: RESULT: PLM=0xffffff8f SS0=0x88888888 SS1=0x00000008
```

很多人以为 `0xffffff8f` 说明"PLM 还锁着"。

**事实**：`PLM` 这个寄存器的正常形态就是 `0xffffff8f`——高位全 1、低字节 `0x8f`。**它不是判据**。真正的判据是 `SS0 = 0x88888888` 和 `SS1 = 0x8`。

**附带教训**：锁定态下 `SS0=0x00002001`。直接往这两个寄存器写 `0x88888888/0x8` 是**无效的**——日志里 `probe:` 那一行就是这次失败尝试的证据：

```
probe: SS0=0x00002001 SS1=0x00000006 after writing 0x88888888/0x8
```

寄存器被 FECS 固件锁住，必须走"SEC2 → FECS 引导 → 写"这条链，让固件自己在正确时机写。

---

## 5. 解锁后一路顺，但驱动报 Code 43

**现象**：U 盘引导成功、`UNLOCKED` 打印了，可进 Windows 后设备管理器黄叹号，属性里写：

> Windows 已停止此设备，因为它报告了问题。（代码 43）

`nvidia-smi` 直接 `No devices were found`.

**原因**：显卡在驱动加载**之前**就处于被解锁的状态，而默认配置下驱动以为自己接管了 FECS——两边对不上，驱动选择拒绝。

**处置**：把驱动实例切到 GSP-RM 模式：

```powershell
# 管理员
.\tools\gsp-mode-ascii.ps1 on
```

它做的事只有一件：在

```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000
```

下面写一个 `EnableGpuFirmware = 1`（DWORD）。**只匹配 `VEN_10DE&DEV_1E07`** 的实例，不会误伤其它显卡。

- 回滚：`gsp-mode-ascii.ps1 off`
- 状态：`gsp-mode-ascii.ps1 status`
- 没有 1E07 实例时会打印 `NO 1E07 INSTANCE FOUND` 并 return 1（此时检查设备管理器里显卡的硬件 ID）

> 已确认的恢复路径：即使忘了这步、报 Code 43，**再重启一次不插 U 盘就完全恢复**，不需要安全模式。

---

## 6. Banner 谎报 FWSEC 哈希

**现象**：你明明放了自己卡的 `1516eb68…`，构建/启动横幅却打：

```
[50HX] native FWSEC c6fa28fa, fb=22G
```

**原因**：那是上游参照卡的哈希，写死在**字符串常量**里，没有跟着 `TU102_ALLOW_FWSEC` 一起改成动态读取。实际嵌进镜像、实际被加载的，是你放进 `blobs/fwsec_native.bin` 的那个 blob——日志中另一行会给出真实尺寸：

```
[50HX fwsec50] native blob @0x11982c000 (0x9a10 B, this card's FWSEC)
```

`0x9a10 = 39440` 字节，正是本卡 FWSEC 的大小。

**处置**：**永远不要用 banner 确认固件身份**。用下面任一方式：

```bash
sha256sum efi-unlock-tu102/blobs/fwsec_native.bin
# 与你从 PROM 里抠出来的 blob 比对

grep -c . <(xxd -p efi-unlock-tu102/TU102UNLK.EFI | tr -d '\n' | grep -o '1516eb68')
```

或者直接看运行日志里的 `native blob ... (0x9a10 B)` 与 `iface@0xdc`——**这两个数字是从真正加载的那个 blob 里读出来的**，撒谎不了。

---

## 7. 日志里的 `@0x400` 也是过期文案

**现象**：

```
fwsec50: BL DESC ctxDma=4 code=0x11982c000(ns0x300@0+sec0x9300@0x400) data=0x119835600(0x410)
```

`sec0x9300@0x400` 里的 `@0x400` 与本卡标定值 `0x300` 不符，容易误判成"常量没改全"。

**事实**：`0x400` 是 `Print()` 格式串里写死的字面量，不是变量。对应的写入代码是正确的：

```c
d[BL_DESC_SECOFF / 4] = FW50_SEC_BASE;   /* = 0x300，本卡标定值 */
Print(L"fwsec50: BL DESC ctxDma=4 code=0x%llx(ns0x%x@0+sec0x%x@0x400)",
      fwsecPhys, FW50_NS_SIZE, FW50_SEC_SIZE, dataPhys, FW50_DMEM_SIZE);
```

注意 `ns0x%x` 打印的 `0x300` 是**变量**（`FW50_NS_SIZE`），是对的；`@0x400` 是**字面量**，只影响观感。

**怎么自证没改错**：紧邻上一行是接口头回读，它从 blob 里现场解出来：

```
fwsec50: data iface@0xdc hdr={1,4,8,2} mapper@0x380 sig=0x50414d44 ver=20545 cmd_in_off=0x3d0 size=0x40
```

- `iface@0xdc` = 标定的 `FW50_IFACE_OFF`
- `mapper@0x380` = 标定的 `FW50_MAPPER_OFF`
- `sig=0x50414d44` = ASCII `"DMAP"`（DMEMMAPPER v3 签名）
- `cmd_in_off=0x3d0` = 标定的 `FW50_CMDIN_OFF`

**如果这四个数对不上，说明常量错了，程序会在这一行之后就失败**。这一行才是真正的"标定校验点"。

---

## 8. `hold 3s WITHOUT reg reads (v57 lesson)`

**现象**：日志里有一句

```
tu102: started; hold 3s WITHOUT reg reads (v57 lesson)
```

如果你把这段"等待"删掉、改成"立刻轮询寄存器看好了没"，会出现**偶发失败**：有时候成功，有时候 FECS 直接不响应，必须重启。

**原因**：SEC2/FECS 启动后的那几秒里，Booter 正在往 mailbox 写结果。此时读 `0x409xxx` 那批寄存器会打断它的时序（可能是读触发了某种 flush 或状态机跳变）。

**处置**：保留这段纯等待，一个字都别优化。之后才允许读：

```
tu102:   cpu=0x10   irq=0x10   dbg=0xdeadb00d   m0=0x0 m1=0x1
```

`cpu=0x10`、`irq=0x10` 是"已停下"的形态；`dbg=0xdeadb00d` 是诊断寄存器残留值，不是错误码。

---

## 9. `[rebar] no 16 GiB-aligned span — skip`

**现象**

```
[rebar] XVE cya=0x00000008 cfg=0x00000002 cap=0x00001c00
[rebar] BAR1 base=0x4000000000 flags=0xc cmd=0x00100007
[rebar] bridge 00:02.0 pref window 0x4000000000..0x40120fffff
[rebar] no 16 GiB-aligned span in window — skip
```

**含义**：程序想给 BAR1 重新分配一个 16 GiB 对齐的地址（ReBAR / resizable BAR 的 pre-OS 版本），但主板的 **PCIe 预取窗口只有约 288 MiB**（`0x4000000000..0x40120fffff`），塞不下。

**这不是错误**：解锁与 ReBAR 是两件独立的事。B760M 这类消费级主板默认预取窗口就这么大，需要 BIOS 里有 "Above 4G Decoding" + 大窗口选项（很多板子干脆没有）。

**要不要在 Windows 里再开 ReBAR**：可以试（NVIDIA Profile Inspector 的 rBAR 设置），但**解锁的收益与 ReBAR 无关**——解锁改的是 tensor 吞吐的倍率，ReBAR 改的是 BAR 窗口映射方式。两者叠加不冲突，也不会互相放大。

---

## 10. B760M 没有 "Fast Boot" 选项

**现象**：各种教程都说"关 Fast Boot"，但 JGINYUE B760M 的 BIOS 里翻遍了也没有。

**事实**：这个选项在部分消费级主板上被移除或改名。**它不影响本流程**——Fast Boot 影响的是 POST 时的设备初始化顺序，而本方案走的是"BIOS 选 U 盘启动"，UEFI 固件会完整初始化 USB 控制器。

替代手段：

- 开机按 **F8 / F11 / F12** 弹一次性启动菜单（不同板子不同键）
- 或在 BIOS 的 Boot 页把 `Boot Option #1` 设成 USB
- 若 U 盘在启动菜单里根本不出现：换 USB 2.0 口（部分板子的 USB 3.x 口在 POST 早期不可用）、确认格式化为 **FAT32**、确认路径是 `\EFI\Boot\BOOTX64.EFI`（大小写敏感）

---

## 11. 转储文件 `head` 不是 `55aa`

**现象**

```
[dump] \tu102_prom_300000.bin head=00000000 (55aa=PCI-ROM ok)
```

**原因**：BAR0 里那个偏移没有映射到 VBIOS ROM 镜像。

**处置**：

- 确认 `capacity=0x2c9` 那行是 OK 的（身份对）；
- 确认 `workspace=0x00000001 (expect 1)` 也是 1——不为 1 说明卡没在预期状态，先别读；
- 换第二个窗口 `BAR0+0x11000` 看（本机那次 `head=0001d0ba`，也不是 PCI ROM 魔数，说明它确实不是主 ROM）；
- 如果两个都是全 0：检查 BIOS 里 `Above 4G` 是否真的生效、以及这块卡是不是被别的固件（例如某些矿卡改的 BIOS）覆盖过。

**安全提示**：转储是**只读**的。读多少次都不会改变卡的状态，放心重试。

---

## 12. 想"永久解锁"——做不到，也不建议

**事实**：解锁状态**只存在于本次开机的 FECS 固件运行态里**。任何一次

- 重启
- 关机再开
- 睡眠变休眠（S4）
- 拔电源

都会回到原厂。这不是程序没写好，是设计如此：写进 VBIOS 才是永久的，但那要动 `0x409664` 所在的固件镜像本身，风险等级完全不同（改坏 = 变砖，且需要 SPI 编程器救）。

**结论**：把它当"每次开机多花 30 秒插 U 盘"的加速模式。需要长跑的任务（训练、批量推理）开机时解锁一次；日常上网不必。

---

## 13. 关于 `altDMEMLoadSize`（0x6618）——别被它带偏

描述符里有四个尺寸字段：

```
IMEMLoadSize      0x9600
DMEMLoadSize      0x0410
altIMEMLoadSize   0x9600
altDMEMLoadSize   0x6618
```

`alt` 版本是给"另一种加载方式"用的（大 DMEM 布局）。本流程走的是标准加载：

- NS 段 `0x300`
- SEC 段 `0x9300`（`0x300 + 0x9300 = 0x9600 = IMEMLoadSize`）
- DMEM `0x410`

**不要**把 `0x6618` 当成 DMEM 大小去填常量——它大 25 倍，会让 `BL DESC` 指向越界区域，表现为加载即失败（而且日志不会直说原因）。

判断用哪套：看 `code_data_contiguous` 为 `true`，说明 code 与 data 在 blob 里连续排列，走标准布局。

---

## 14. 两个"另一个自己"：prod 与 dbg

描述符里同一份 FWSEC 有两条记录：

| | `prod` | `dbg` |
|---|---|---|
| `rom_desc_offset` | `0x3f200` | `0x357b4` |
| `blob_sha256` | `1516eb68…` | `e2b7fe15…` |

**几何完全一样**，只有内容（哈希）不同——`dbg` 是带调试输出的同名固件。

**用 prod**。用 dbg 会多打印一堆 trace，理论上更慢，而且它是给 NVIDIA 内部调试用的，行为未验证。

判别方法：解析时同时打印两条的 8 个几何字段，若 `IMEMLoadSize/DMEMLoadSize/InterfaceOffset/IMEMSecBase/IMEMSecSize` 全等，说明你找到了同一家族的两个变体，选 `prod`。

---

## 15. 检验清单：出问题时按这个顺序看

如果 `UNLOCKED` 没打出来，**从上往下**逐项确认，每项都有明确日志锚点：

| # | 检查 | 期望日志 |
|---|---|---|
| 1 | 卡被识别 | `id=0x1e0710de` |
| 2 | 容量守卫 | `capacity=0x000002c9 OK` |
| 3 | 前置状态 | `workspace=0x00000001 (expect 1)` |
| 4 | 架构字段 | `BOOT0=0x162000a1`（高字节 `0x16`） |
| 5 | FWSEC 载入 | `native blob @0x… (0x9a10 B` |
| 6 | 标定校验 | `iface@0xdc … mapper@0x380 sig=0x50414d44 … cmd_in_off=0x3d0` |
| 7 | WPR2 上报 | `*** WPR2 UP lo=0x057fe000 hi=0x057fee00` |
| 8 | IMEM/DMEM 回读 | `IMEM[0]=0xce100049(exp 0xce100049)` |
| 9 | 启动后静置 | `started; hold 3s WITHOUT reg reads` |
| 10 | 状态轮询 | `cpu=0x10 irq=0x10` |
| 11 | **判定** | `SS0=0x88888888 SS1=0x00000008` |

**第 6 步失败**（sig 不是 `0x50414d44`）→ 一定是常量错了，回到 [02-fwsec-calibration.md](02-fwsec-calibration.md) 重新从 PROM 里推，不要靠猜。

**第 8 步失败**（`exp` 与实际不符）→ FWSEC 没有正确落进 IMEM，检查 `FW50_CODE_SIZE` / `FW50_DATA_OFF` 是否相等且等于 `IMEMLoadSize`。

**第 10 步失败**（`cpu` 不是 `0x10`）→ 检查 SEC2 是否被上一次失败的运行留在坏状态；执行一次完整断电重启（拔电源 10 秒）再来。
