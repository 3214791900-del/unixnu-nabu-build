# 夜间自动推进报告（最终版，2026-10-22 23:56）

## 一句话

内核日志从「完全不可见」变成「本地 QEMU 完整可读」，真机 IOSurface 卡点定性为
「闭源 kext 不可用」，并已把 **mockfs 编入内核**（构建成功，待真机验证）。

---

## 一、做成了什么

### 1. QEMU 秒级验证环境（今晚的核心产出）

本地 QEMU 现在能打印真实内核日志：

```
NABU                                    <- UART 映射成功的标记
kprintf initialized
Serial mode specified: 00000003
initialize_screen: b=23C7A0000, w=320, h=258, r=0xC80
pe_arm_init_interrupts: args: 0xfffffff007a62860
corecrypto_kext_start (tracing disabled)
FIPSPOST_KEXT ... all tests PASSED (1690 ms)
corecrypto_kext_start completed successfully
ulock_initialize>thread_max=1536, ull_hash_buckets=512
```

**一轮 40 秒**（对比：CI 8.5 分钟 + 刷机 + 拍照）。

### 2. 四道关，每道一个明确根因

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 完全无日志 | `kprintf` 的门是 `if (!disable_serial_output && !disable_kprintf_output)`，**两个默认都是 true** | 两个都清 |
| 2 | 清了仍无日志 | `PE_init_kprintf` 在 `STARTUP(KPRINTF)` 跑，早于 fb 映射，按就绪判断导致 hook 永不安装 | 无条件赋值 |
| 3 | UART 也不输出 | `0x9000000` 是**物理地址**，未映射即 fault | `ml_io_map_unmappable` 先映射 |
| 4 | Undefined Instruction | `cortex-a72` 不认 `MSR S3_0_C4_C1_4` | **`-cpu max`** |

### 3. QEMU 的边界（已定位到指令级）

`ulock_initialize()` 之后 **Data Abort**：

```
ESR 0x96000005   data abort, translation fault level 1
FAR 0x0          空指针
ELR 0xfffffff004a92828   在 __PLK_TEXT_EXEC（prelink kext 代码）
```

**真机能过这一步**，所以这是 QEMU 缺硬件，不是内核缺陷。

### 4. 真机 IOSurface 卡点的本质

`IOsurfaceRoot:installMemoryRegions()` 之后卡住，**不是断言、不是内存不足**，
是 **Apple 闭源 IOSurface kext 在非 Apple 平台上跑不通**。

ios-nabu 的解法：**重写** `NabuSurface.cpp`（IOCoreSurfaceRoot）+
`NabuFramebuffer.cpp`（AppleCLCD）并注册进 `KernelConfigTables`。

### 5. mockfs 编入内核（本轮代码成果）

`config/MASTER.arm64.bcm2837` 的 `FILESYS_BASE` 加上 `mockfs`
（`zzzz-nabu-mockfs-root.patch`）。**CI 构建成功**，kernel 51.03 MB。

顺带发现：`null-root-media.patch` **已经** 把 `setRootMedia()` 包在 `if (root)` 里，
所以无 block storage driver 时那个 assert 根本到不了——我原计划的第二处修改是多余的。

### 6. 差距重新盘点（重要修正）

审计自己的 `patches/xnu/` 后，**阶段 1、2 的大部分其实已经有了**：

| 能力 | 我们已有 |
|---|---|
| mockfs 编译修复 | `mockfs-typed-allocation` / `-statfs` / `-intermediate-lookup` / `-memory-device-width` / `-test-file` |
| 无 block storage 容忍 | `null-root-media` |
| trust cache 运行时 | `native-trust-cache-runtime` |
| **pthread** | `source-pthread-bootstrap`（新增 `bsd/kern/source_pthread_bootstrap.c`）|
| SMP | `native-smp-secondary` |
| panic 区 | `native-dt-panic-region` |
| work interval | `native-priv-work-interval` |

**真正的空白只剩四处**：
1. **RNG 不依赖 corecrypto**（ios-nabu 0013）
2. **iowatchdog**（0040，缺了会看起来像随机重启）
3. **AMFI 无 entitlements**（0025）
4. **自研 surface / framebuffer**（0046，**最大差距**）

---

## 二、卡住的地方

**设备在 `recovery` 模式，不在 `fastboot`**：

```
$ fastboot devices           (空)
$ adb devices
f91fa664    recovery
```

所以 **mockfs 那版没能刷到真机验证**。需要手动：
`adb reboot bootloader` 或长按进 fastboot。

---

## 三、明天可以立刻做的

| # | 动作 | 预计 | 依据 |
|---|---|---|---|
| 1 | 设备切 fastboot，刷 mockfs 版，看能否越过 `cannot mount root` | 10 分钟 | 本轮构建 |
| 2 | 补 **RNG 不依赖 corecrypto** | 半天 | ios-nabu 0013 |
| 3 | 补 **iowatchdog** | 2 小时 | 0040 |
| 4 | 补 **AMFI 无 entitlements** | 半天 | 0025 |
| 5 | **决策点**：自研 surface（几周）vs 切 8796（一周）| — | — |

---

## 四、诚实的总结

**做成的**：把「看不见」变成「看得见」，并且把差距量化到了 patch 级别。

**没做成的**：内核在真机上**没有比昨晚跑得更远**（仍卡 IOSurface），
mockfs 那版还没上真机验证。

**最大的判断**：我们其实比想象中接近——阶段 1、2 大部分已经有了，
真正的空白是 **RNG / watchdog / AMFI / surface** 四块，其中 surface 是唯一的周级任务。
