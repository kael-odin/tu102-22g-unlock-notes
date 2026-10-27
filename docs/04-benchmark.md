# 04 · 基准方法与数据

本仓只有一个目的：**用最小、可复现、可证伪的方式，证明这张卡在解锁态下 tensor FP16 吞吐超过了锁定态的物理上界。**

所有数字都是本机实测，原始 JSON 在 [`bench/results-2080ti-22g-1e07.json`](../bench/results-2080ti-22g-1e07.json)。

---

## 1. 为什么选 GEMM

Turing 的限制很具体：**FP16 输入、FP32 累加的矩阵乘**（tensor core 的主用法）被限制在半速。所以最直接的验证方式就是跑这个形状的 GEMM，而不是跑任何"综合分"。

- 用 `torch.matmul`（底层 cuBLAS），不做任何自定义 kernel —— 排除"我写了个更快的实现"这种解释
- 用方阵，边长 2048 / 3072 / 4096 —— 边长足够大，launch 开销和边界效应占比小
- FP32 GEMM 作为**对照组** —— 它不受这个限制，必须基本不动

---

## 2. 环境

| 项 | 值 |
|---|---|
| GPU | NVIDIA GeForce RTX 2080 Ti（TU102，68 SM，显存 21.7 GiB 可见） |
| PCI ID | `10de:1e07`，subsys `10de:12a4` |
| VBIOS | `90.02.0b` 家族 |
| 驱动 | 617.42 |
| PyTorch | 2.11.0+cu128 |
| CUDA runtime | 12.8 |
| 时间 | 2026-10-27 10:30:34 |
| 状态 | **本次开机已解锁**（同一开机内完成引导 → 进系统 → 立即测） |

`nvidia-smi` 的显存显示为 22528 MiB；PyTorch 报 `total_memory/2**30 = 21.7 GiB`，差额是驱动预留，正常。

---

## 3. 脚本

完整代码：[`bench/bench_gemm.py`](../bench/bench_gemm.py)。核心只有三段。

### 3.1 关掉两个会污染结果的开关

```python
torch.backends.cuda.matmul.allow_tf32 = False   # Turing 没有 TF32 路径，纯防御
torch.backends.cudnn.benchmark = False          # 用固定算法，别让 autotune 在计时里跑
```

### 3.2 计时窗口

```python
def bench(mode, n, warmup=10, iters=30):
    a = torch.randn((n, n), device=dev, dtype=mode)
    b = torch.randn((n, n), device=dev, dtype=mode)
    for _ in range(warmup):
        c = a @ b
    torch.cuda.synchronize()
    times = []
    for _ in range(iters):
        s, e = torch.cuda.Event(True), torch.cuda.Event(True)
        s.record()
        c = a @ b
        e.record()
        torch.cuda.synchronize()
        times.append(s.elapsed_time(e))     # ms
    med = statistics.median(times)
    tflops = 2 * n**3 / (med / 1e3) / 1e12
    return med, tflops
```

三个刻意的选择：

- **`cuda.Event` 而不是 `time.time()`** —— 测的是 GPU 侧执行时间，不含 Python 开销和 launch 排队
- **每次迭代都 `synchronize`** —— 避免多次 kernel 叠在队列里互相影响；代价是多了同步开销，但方阵 GEMM 动辄 1 ms 以上，占比可忽略
- **取 `median` 而不是 `mean`** —— 少数离群值（时钟抖动、驱动抢占）不会拖动结果

### 3.3 输出

`2 * n³` 是 GEMM 的浮点运算数（乘加各算一次），除以秒数、除 1e12 得 TFLOPS。结果写 JSON，`meta` 里带上 GPU/SM/显存/torch/cuda/时间戳。

---

## 4. 原始结果

```json
{
  "meta": {
    "gpu": "NVIDIA GeForce RTX 2080 Ti",
    "sms": 68,
    "vram_gib": 21.7,
    "torch": "2.11.0+cu128",
    "cuda": "12.8",
    "timestamp": "2026-10-27 10:30:34",
    "power_state_note": "record nvidia-smi power/clocks separately"
  },
  "fp16_gemm_fp32acc": {
    "2048": { "median_ms": 0.215, "tflops": 79.97 },
    "3072": { "median_ms": 0.770, "tflops": 75.27 },
    "4096": { "median_ms": 1.434, "tflops": 95.87 }
  },
  "fp32_gemm_control": {
    "2048": { "median_ms": 1.282, "tflops": 13.40 }
  }
}
```

| 形状 | dtype | 中位耗时 | TFLOPS | 对照峰值 | 效率 |
|---|---|---|---|---|---|
| 2048³ | FP16 / FP32累加 | 0.215 ms | 79.97 | 107.6 | 74.3% |
| 3072³ | FP16 / FP32累加 | 0.770 ms | 75.27 | 107.6 | 70.0% |
| 4096³ | FP16 / FP32累加 | 1.434 ms | 95.87 | 107.6 | **89.1%** |
| 2048³ | FP32 | 1.282 ms | 13.40 | 13.45 | 99.6% |

峰值口径：2080 Ti 的 tensor FP16（FP32 累加、非稀疏）**解锁后**为 **107.6 TFLOPS**，**锁定态为其一半，53.8 TFLOPS**；FP32 为 **13.45 TFLOPS**。

---

## 5. 怎么读这组数

### 5.1 三个都需要成立

**① FP16 必须明显超过 53.8。** 最小的 2048³ 也有 79.97，**是锁定态上限的 1.49 倍**。这不是"优化得好"，是物理上不可能——锁定态的硬件路径就是半速。

**② FP32 必须基本不动。** 13.40 vs 规格 13.45 = 99.6%。如果这是超频导致的整体提速，FP32 会一起涨；它没涨，说明提速只发生在 tensor 路径上。

**③ 最大的 4096³ 效率最高。** 89.1% 是合理的：方阵边长越大，kernel 时间越长，固定开销（launch、尾块）占比越低，越接近峰值。

### 5.2 为什么 3072³ 比 2048³ 还低

这是本组数据里唯一"看着不自然"的地方，**不做因果归因**，只列可能：

- 三个形状**顺序执行**（2048 → 3072 → 4096），2048 最先跑，GPU 温度最低、boost 最高；3072 时已经在耗电升温过程中
- 3072 不是 2 的幂，cuBLAS 的 tile 划分可能产生更多尾块
- 本机**没有并发采集功耗/频率**（JSON 里 `power_state_note` 就是提这件事），所以无法区分上面两种

如果要做严谨归因，用 `nvidia-smi --query-gpu=clocks.sm,clocks.mem,power.draw,temperature.gpu --format=csv -l 1` 在另一个窗口持续采样，再和 `times` 对齐。本仓没做，所以不声称。

### 5.3 精度：本仓没测

脚本不含数值校验。要自测（推荐，尤其是担心解锁会影响正确性时）：

```python
n = 512
a = torch.randn((n, n), device="cuda", dtype=torch.float16)
b = torch.randn((n, n), device="cuda", dtype=torch.float16)
c16 = (a @ b).double()
c64 = a.double() @ b.double()
print(((c16 - c64).abs() / c64.abs().clamp_min(1e-6)).max().item())
```

FP16 输入 + FP32 累加的正常误差量级是 `1e-4`～`1e-3`（取决于矩阵条件数）。上游在**另一张卡**上测得最大相对误差 `2.5e-4`，可作参考，但**不是本机数据**。

### 5.4 为什么不能和上游数据横向比较

上游公开的 4096³ 数字是 **80.3～81.3 TFLOPS**，看起来比本仓的 95.87 低。差异全部来自方法学，不是卡：

| | 本仓 | 上游 |
|---|---|---|
| 卡 | `1E07` / VBIOS `90.02.0b` | `1E04` / VBIOS `90.02.33.00.2f` |
| 驱动 | 617.42 | 621.01 |
| 平台 | Intel B760 + i5-12400F | AMD B350 + 5700X3D |
| 预热 / 计时 | **10 / 30** | **200 / 100** |
| 性质 | 短时中位数（burst） | 持续时间（sustained） |

**200 次预热 + 100 次计时**意味着 GPU 已经被压到稳定功率/温度状态，读数会落在持续功耗墙以内——这正是 80 左右这个数字更可信的原因。本仓的 10 + 30 太短，读数包含 boost 尾巴，**偏高是预期行为**。

所以正确的表述是：

> 本卡短时中位数 95.87 TFLOPS；同型号另一张卡在 200+100 次持续压测下为 80.3～81.3 TFLOPS。两者不是同一个量，不能比较卡的好坏。

想得到可比的持续值，把 `bench()` 改成 `warmup=200, iters=100` 重跑即可——代价是 4096³ 要跑约 5 分钟。

---

## 6. 锁定态基线怎么补

本仓**没有**在锁定态下跑同一份脚本（那需要重启、跳过 U 盘引导，再进系统跑一次）。所以"提升倍数"不是本机 A/B 得出的，而是从**物理上界**推的：`107.6 / 53.8 ≈ 2.0`。

想补齐 A/B，按这个顺序做：

```powershell
# 1. 正常开机（不插 U 盘），确认已回原厂
nvidia-smi --query-gpu=name,memory.total --format=csv

# 2. 跑同一份脚本
python bench\bench_gemm.py bench\results-locked.json

# 3. 比对
```

期望：FP16 全部落在 **50～54 TFLOPS**，FP32 落在 13.4 附近（几乎不变）。

如果锁定态 FP16 也跑到 79，那说明**卡根本没被限制**（某些非零售 SKU / 已被厂商改过 VBIOS），此时解锁无意义，本方案对它没有收益。

---

## 7. 结论的边界

**能说的**：

- 本机、本驱动、本脚本下，FP16 FP32-累加 GEMM 达到 95.87 TFLOPS
- 该值超过锁定态物理上界（53.8）1.78 倍，因此**解锁确实生效**
- FP32 路径未提速（13.40 ≈ 规格 13.45），因此**不是超频或整体加速**
- 4096³ 达到理论峰值的 89.1%

**不能说的**：

- ❌ "所有负载都能快一倍" —— 只有 tensor FP16/tensor 路径受益。FP32 计算、显存带宽密集型、光栅化游戏性能都不变（甚至因为失去 FP16 半速特性而在某些混合精度 kernel 上有微小差异）
- ❌ "比 2080 Ti 原厂快 1.78 倍" —— 是"比被限制的 tensor 路径快"，不是"比显卡快"
- ❌ "本卡比上游那张卡快" —— 方法学不同，见 §5.4
- ❌ "持续负载下也是 95 TFLOPS" —— 那是 burst 值
- ❌ "解锁后的精度有问题/没问题" —— 本仓没测精度

---

## 8. 对实际工作负载的意义

如果你的任务吃 `torch.matmul` / attention 的 FP16 且累加在 FP32（绝大多数 transformer 训练与推理都属于此类），那么：

- 理论吞吐上限翻倍
- 实测能拿到多少取决于 kernel 效率、显存带宽、batch 形状——**不等于翻倍**
- 上下文超长、batch 很小的场景会被访存和调度主导，收益远低于 2×

本机曾做过一次真实负载观测（KV 缓存长上下文的 decode），结论是**出字速度几乎无变化**——那类负载是访存瓶颈，不是 tensor 算力瓶颈。这正好说明为什么本文坚持用 GEMM 峰值来证明解锁，而不用某个应用的帧率/速度来宣称收益。

**一句话**：解锁提升的是**算力上限**，不是你的程序速度。能不能落到你的任务上，取决于你的任务是不是算力瓶颈。
