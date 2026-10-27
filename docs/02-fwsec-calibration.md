# 02 · FWSEC 标定方法

这一节回答一个问题：**为什么换个 VBIOS 家族就必须重新算 10 个常量，怎么算。**

如果你只想照抄本卡的数值，去 [01-walkthrough.md](01-walkthrough.md#5-阶段-2--构建解锁版)；如果照抄后 `sig` 对不上（[03-pitfalls.md](03-pitfalls.md#7-日志里的-0x400-也是过期文案)），回来读这里。

---

## 1. 为什么会有"标定"这回事

解锁链最后一步要用 **FECS Booter** 去引导 **FWSEC** 固件。这中间需要填一个 `BL DESC`（boot descriptor）结构，告诉 FECS：

- 固件镜像在哪、多大
- 里面哪一段是 NS（非安全）、哪一段是 SEC（安全）
- 安全段的入口在 IMEM 的哪个物理偏移
- DMEM 数据在哪、多大
- 接口头（`FWSEC_IFACE`）在 DMEM 里的哪个位置
- 命令入队缓冲区（`cmd_in_buffer`）在哪

这些**全是固件布局的属性**，而布局随 VBIOS 版本变化——不同批次、不同显存容量的卡，NVIDIA 会把 FWSEC 重新编译、重新排布。**拿参照卡的常量去喂你的卡，轻则 `sig` 校验失败、链路停在第一步，重则把错的地址写进 IMEM，需要断电重启。**

好消息：**布局信息就写在你自己的卡里**。VBIOS ROM 里带一份 FWSEC 镜像，镜像带一份自描述容器，容器里有全部几何字段。标定 = 把它读出来，不是逆向猜测。

---

## 2. 输入：你自己的 PROM 转储

`tu102_prom_300000.bin`（1 MiB，BAR0 + 0x300000），来源见 [01-walkthrough.md](01-walkthrough.md#3-阶段-0--只读转储不需要任何固件)。

先做一件事：确认魔数。

```bash
xxd -l 64 tu102_prom_300000.bin
# 00000000: 55aa ...                                     U.
```

`55aa` = PCI ROM 签名。不是它，说明读错了偏移，别往下走。

---

## 3. 定位：三层指针

FWSEC 不是明文躺在 ROM 里，它被包在一个**自描述的 bitcode 容器**里。定位要穿过三层：

```
PROM 基址
  └─ +0x11600   pointer base：一组指向容器的指针表
       └─ +0x1b0    bit header：容器头
            └─ +0x20324  table：条目表，每条描述一个固件镜像
                          ├─ 条目 A → rom_desc_offset = 0x3f200   (prod)
                          └─ 条目 B → rom_desc_offset = 0x357b4   (dbg)
```

这三个数字（`0x11600` / `0x1b0` / `0x20324`）是**本卡 VBIOS 90.02.0b 的实测坐标**，不同 VBIOS 会变。找它们的方法是扫表而不是背数值：

1. 在 ROM 里找连续的、落在 ROM 范围内的 32 位小端值，筛选出指向"结构头"的那些；
2. 结构头之后跟一张定长条目表，每条里的 `StoredSize` 字段都应当是"看起来像固件大小"的值（几 KB 到几十 KB，且 4 字节对齐）；
3. 用 `StoredSize` 去 ROM 里反查：`rom_desc_offset + 头部开销 + StoredSize` 应当正好落在 `rom_data_offset` 之后不远——`code_data_contiguous=true` 的镜像，`rom_code_offset + IMEMLoadSize == rom_data_offset`。

这三条自洽约束一起用，比任何单一特征都可靠。

> **别手算字段偏移。** 描述符里的字段是按固定顺序排列的，用脚本按名取值（本仓 `docs/` 只放结果，脚本随工作目录）。手算一位就有可能错位 4 字节，而错位后的数值看起来仍然"像个地址"——这是最难查的一类错误。

---

## 4. 产出：本卡的描述符

解析结果存成 JSON，作为后续所有常量的**唯一来源**：

```json
{
  "source": "local-dump/tu102_prom_300000.bin",
  "pointer_base": "0x11600",
  "bit_header": "0x1b0",
  "table": "0x20324",
  "prod": {
    "rom_desc_offset": "0x3f200",
    "rom_code_offset": "0x3f23c",
    "rom_data_offset": "0x4883c",
    "code_data_contiguous": true,
    "vDesc": "0x3c0201",
    "StoredSize": "0x9a10",
    "UncompressedSize": "0x9a10",
    "VirtualEntry": "0x0",
    "InterfaceOffset": "0xdc",
    "IMEMPhysBase": "0x0",
    "IMEMLoadSize": "0x9600",
    "IMEMVirtBase": "0x0",
    "IMEMSecBase": "0x300",
    "IMEMSecSize": "0x9300",
    "DMEMOffset": "0x9600",
    "DMEMPhysBase": "0x0",
    "DMEMLoadSize": "0x410",
    "altIMEMLoadSize": "0x9600",
    "altDMEMLoadSize": "0x6618",
    "blob_size": 39440,
    "blob_sha256": "1516eb686e3b4a379f9c5739720b4ebf938700c2b5bf65686006ccd3999e2227"
  },
  "dbg": {
    "rom_desc_offset": "0x357b4",
    "blob_sha256": "e2b7fe1502fa645457ced15e899eaaaf86330fcaa25ba781a6a65bc71de4b0c6",
    "…geometry identical…": true
  }
}
```

**先看三个数，它们互相锁定**：

| 量 | 值 | 关系 |
|---|---|---|
| `StoredSize` | `0x9a10` | = `UncompressedSize`，说明未压缩 |
| `blob_size` | 39440 | = `0x9a10`，交叉验证 |
| `rom_data_offset − rom_code_offset` | `0x4883c − 0x3f23c` | = `0x9600` = `IMEMLoadSize` |

最后一条是关键：**code 段与 data 段在 ROM 里是背靠背排列的**（`code_data_contiguous=true`）。所以你可以直接用 `rom_code_offset` 起、取 `StoredSize` 字节，得到一个完整 blob，再按 `IMEMLoadSize` 切成两半。

```bash
dd if=tu102_prom_300000.bin of=fwsec_prod.bin bs=1 skip=$((0x3f23c)) count=$((0x9a10))
sha256sum fwsec_prod.bin
# 1516eb686e3b4a379f9c5739720b4ebf938700c2b5bf65686006ccd3999e2227
```

哈希对得上，说明切得对。

---

## 5. 从描述符到 10 个常量

C 侧的常量与描述符字段的对应关系是直接的，**不要做推理，只做搬运**：

| C 宏 | 值 | 描述符字段 | 含义 |
|---|---|---|---|
| `FW50_CODE_SIZE` | `0x9600` | `IMEMLoadSize` | 整个 code 段（NS+SEC）长度 |
| `FW50_DATA_OFF` | `0x9600` | `DMEMOffset` | data 段在 blob 内的起点 |
| `FW50_DMEM_SIZE` | `0x0410` | `DMEMLoadSize` | DMEM 数据长度 |
| `FW50_BLOB_SIZE` | `0x9A10` | `StoredSize` | blob 总长 |
| `FW50_IFACE_OFF` | `0x00DC` | `InterfaceOffset` | 接口头在 DMEM 内的偏移 |
| `FW50_MAPPER_OFF` | `0x0380` | 见 §6 | DMEMMAPPER v3 条目 |
| `FW50_CMDIN_OFF` | `0x03D0` | 见 §6 | `cmd_in_buffer` |
| `FW50_NS_SIZE` | `0x0300` | `IMEMSecBase` | 非安全段长度 |
| `FW50_SEC_BASE` | `0x0300` | `IMEMSecBase` | 安全段在 IMEM 的起址 |
| `FW50_SEC_SIZE` | `0x9300` | `IMEMSecSize` | 安全段长度 |

注意 `NS_SIZE` 与 `SEC_BASE` **数值相同但不是同一个概念**：前者是"前面那一截有多长"，后者是"安全段该落在 IMEM 的哪个地址"。因为这个固件的 NS 段正好加载到 IMEM 偏移 0，两者才撞了值。换一个家族时它们可能不同，别用同一个变量顶替。

---

## 6. mapper 与 cmd_in 需要多走一步

`InterfaceOffset` 直接给了，但 `MAPPER_OFF` / `CMDIN_OFF` 不在描述符里——它们在**接口头之后的映射表**里。

接口头在 `DMEM + InterfaceOffset`（本卡 `0xdc`），结构是四个 32 位值：

```
hdr = {1, 4, 8, 2}
      │  │  │  └─ 2 = 映射表条目数
      │  │  └──── 8 = 条目大小（字节）
      │  └─────── 4 = 表项数上限
      └────────── 1 = 版本
```

表项是 `id + 偏移` 的形式。要找的两项：

- **`id = 4`** → DMEMMAPPER v3 → 得到 `MAPPER_OFF`
- **`DMAP[2]`** → `cmd_in_buffer` → 得到 `CMDIN_OFF`

校验方法：mapper 处应当有 4 字节签名 **`0x50414d44`**，小端读作 ASCII 就是 **`"DMAP"`**。没有这个签名，说明 `InterfaceOffset` 找错了。

**这一步不用你手算**：程序在运行时会把它们从 blob 里现场读出来并打印，见 [03-pitfalls.md](03-pitfalls.md#7-日志里的-0x400-也是过期文案)：

```
fwsec50: data iface@0xdc hdr={1,4,8,2} mapper@0x380 sig=0x50414d44 ver=20545 cmd_in_off=0x3d0 size=0x40
```

**这四个数全部对上，才说明标定正确。** 它是整条链里最硬的校验点——因为它们是从真正加载的那个 blob 里解出来的，谁也没法替你蒙对。

---

## 7. 三条不变量：换家族时的自检

标定完，用这三条互相验证。任何一条不成立，说明中间有字段取错了：

| 不变量 | 本卡 | 说明 |
|---|---|---|
| `BLOB_SIZE == CODE_SIZE + DMEM_SIZE` | `0x9A10 == 0x9600 + 0x410` ✓ | blob 由 code+data 构成，无额外填充 |
| `SEC_BASE + SEC_SIZE == CODE_SIZE` | `0x300 + 0x9300 == 0x9600` ✓ | 安全段正好铺满 code 段、且接在 NS 之后 |
| `CMDIN_OFF − MAPPER_OFF == 0x50` | `0x3D0 − 0x380 == 0x50` ✓ | 接口表条目间距固定 |

第三条是**跨家族不变的经验值**：上游参照卡（`c6fa28fa`，`0xE0/0x390/0x3E0`）同样满足 `0x3E0 − 0x390 = 0x50`。如果你算出来不是 `0x50`，几乎肯定是 `id=4` 条目选错了表项。

前两条是**本家族的**：`0x9A10 = 0x9600 + 0x410` 正好整除，说明没有 compression、没有 alignment padding。若你的卡 `BLOB_SIZE` 比 `CODE_SIZE + DMEM_SIZE` 大，先去看 `UncompressedSize` 是否等于 `StoredSize`——不等说明是压缩的，本流程不支持。

---

## 8. prod vs dbg：选哪个

同一份 JSON 里有两组：

| | prod | dbg |
|---|---|---|
| `rom_desc_offset` | `0x3f200` | `0x357b4` |
| `blob_sha256` | `1516eb68…` | `e2b7fe15…` |
| 几何 | 全部相同 | 全部相同 |

**用 prod。** `dbg` 是带 trace 的调试版，行为未验证、输出更多、体积可能不同（本例几何相同，但不保证所有家族都相同）。

判别方法很简单：把两条的 `IMEMLoadSize / IMEMSecBase / IMEMSecSize / DMEMLoadSize / InterfaceOffset` 打出来对比，全等 → 同一家族的两个变体；不等 → 你选错条目了，回头检查表项遍历。

---

## 9. 换成别的 VBIOS 家族要重做什么

完整清单，一步都不能跳：

1. 重新做一次**只读转储**（[01-walkthrough.md](01-walkthrough.md#3-阶段-0--只读转储不需要任何固件)）——不能拿本仓的 PROM 顶替
2. 重新定位三层指针，确认 `StoredSize` 自洽
3. 重新算 10 个常量，过三条不变量
4. 重新算 blob 的 SHA-256，**与任何已知值对比都应该不同**（不同 = 对了）
5. 构建时带 `TU102_ALLOW_FWSEC=1`
6. 引导后**先看 `iface@… sig=0x50414d44` 那一行**，通过了再看 `UNLOCKED`

**不需要重做的**：`v67_payload` / `booter_ucode_prod` / `gsp_rm_boot_dbg` / `bl_gsp_tu102` 四个公共 blob 与卡的 VBIOS 无关（它们是驱动侧/引导侧的公共件），本仓 `tools/get-blobs.sh` 里钉了四个哈希，可直接复用。

---

## 10. 三种典型错法

| 错法 | 症状 | 为什么 |
|---|---|---|
| 直接用参照卡的 10 个常量 | `sig` 不是 `0x50414d44`，链路停在 `fwsec50` 之后 | 布局不同，`InterfaceOffset` 指到了别处 |
| 把 `altDMEMLoadSize`(`0x6618`) 当 `DMEMLoadSize` | 加载立即失败，无明确报错 | 越界，BL DESC 描述了不存在的内存 |
| `NS_SIZE` 与 `SEC_BASE` 只改一个 | `SEC_BASE + SEC_SIZE ≠ CODE_SIZE`，第 8 步 IMEM 回读失败 | 两者在本家族数值相同但语义不同，改了要一起改 |

第三种的坑最隐蔽：因为两个宏的值一样，很多人以为"改一个就够了"。

---

## 11. 一句话总结

> 标定不是"猜常量"，是**从你自己的 ROM 里把固件自己的自描述读出来**。
> 三条不变量保证搬运没错位，运行时的 `sig=DMAP` 保证整体没错。
> 只要这两道关都过，剩下的就是机械流程。
