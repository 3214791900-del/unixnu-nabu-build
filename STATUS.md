# 夜间自动推进报告（2026-10-22 22:51 更新）

## 今晚最重要的成果：QEMU 秒级验证环境**完全打通**

```
NABU                                                          <- UART 映射成功
kprintf initialized
Serial mode specified: 00000003
initialize_screen: b=23C7A0000, w=320, h=258, r=0xC80
pe_arm_init_interrupts: args: 0xfffffff007a62860
corecrypto_kext_start (tracing disabled)
FIPSPOST_KEXT ... all tests PASSED (1690 ms)
corecrypto_kext_start completed successfully
ulock_initialize>thread_max=1536, ull_hash_buckets=512        <- 停在这
```

**这是第一次在本地看到内核的完整日志文本**，不用刷机、不用拍照。
一轮验证 = **40 秒**（对比：CI 8.5 分钟 + 刷机 2 分钟 + 拍照）。

## 打通的四道关（每道都有明确根因）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 内核完全没有日志 | kprintf 门是 `if (!disable_serial_output && !disable_kprintf_output)`，**两个都默认 true** | 两个都清 |
| 2 | 清了还是没日志 | `PE_init_kprintf` 在 `STARTUP(KPRINTF)` 跑，早于 fb 映射，按就绪判断导致永不赋值 | 无条件 `PE_kputc = nabu_mark_putc` |
| 3 | UART tag 也不出现 | `0x9000000` 是**物理地址**，内核 VM 里没映射，写入 fault 被吞 | `ml_io_map_unmappable` 映射后再写 |
| 4 | 内核撞 Undefined Instruction | QEMU `-cpu cortex-a72` 不认识 `MSR S3_0_C4_C1_4` | 换 **`-cpu max`** |

## QEMU 的当前边界（重要）

停在这里（`STARTUP(EARLY_BOOT, RANK_FIRST)`）：

```c
static void ulock_initialize(void) {
    ull_bucket = zalloc_permanent(...);        // <- 卡住
}
```

**真机能过这一步**（真机已经跑到 IOKit），所以这是 **QEMU 缺硬件/内存布局差异**，
不是内核 bug。**QEMU 的验证深度到此为止**——再往后需要真实硬件。

## 环境与脚本（都已可复用）

| 件 | 位置 |
|---|---|
| Mu_Basecore（EDK2）| `UniXNU/package/Mu_Basecore` |
| UniXNU.efi（94 KB）| `package/Build/Out/AARCH64-DEBUG/UniXNU.efi` |
| DarwinBoot.efi（36 KB）| `package/Build/UniXNU/DEBUG_GCC/AARCH64/DarwinBoot.efi` |
| QEMU ESP | `C:\Temp\auto\esp` |
| QEMU 设备树 | `C:\Temp\auto\qemu.adt`（`make-dt.py --armvirt --armcpu --smp 1`）|
| 截图 | `shot.ps1`（QMP screendump -> PNG）|
| 全自动 | `loop.ps1`（触发 CI -> 等 -> 下载 -> QEMU -> 报告）|

**关键 QEMU 参数**（缺一个都不行）：

```
-M virt -cpu max -m 8192 -smp 1
-drive if=pflash,...,file=edk2-aarch64-code.fd
-drive if=none,id=esp,...,file=fat:<ESP目录>
-device virtio-blk-pci,drive=esp -device ramfb
-display none -serial file:<log>
```

- `-cpu max`（不是 cortex-a72）：否则未定义指令
- `-m 8192`：4096 时 DarwinBoot 报 `boot refused: Out of Resources`
- ESP 用**目录**（`fat:`），不用做 img

## 真机那条线（IOSurface）

**已查清本质**：`IOsurfaceRoot:installMemoryRegions()` 之后卡住，
是 **Apple 闭源 IOSurface kext 在非 Apple 平台上跑不通**。

ios-nabu 的解法是**自己重写**：`NabuSurface.cpp`（IOCoreSurfaceRoot）+
`NabuFramebuffer.cpp`（AppleCLCD），注册进 `KernelConfigTables`。
**周级工作量**，不是几轮 patch 能过的。

## 建议的下一步

1. **QEMU 这条路**：已到边界。想再深入要给 QEMU 补 MMIO 设备模拟，性价比不高
2. **真机这条路**：`bsd_autoconf` 之后到 root mount 之间还有几个已知卡点，
   且 `rootvp not authenticated` 已提前修掉
3. **最大决策点**：IOSurface 段是否要自己写 surface/framebuffer 驱动
   - 自己写：几周
   - 借 ios-nabu：今天就能到他们位置（同设备、同 iPadOS 16.6.1）

## 诚实总结

**今晚把「看不见」变成了「看得见」**——内核日志从零到完整，QEMU 从零到能跑。
**但没有让内核跑得更远**：真机仍在 IOSurface，QEMU 新边界在 ulock。

真正的进展是**工具链**，不是**功能**。明天可以基于这套工具快速迭代。
