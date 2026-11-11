# 小米平板5（nabu）刷 iOS —— 完整技术资料

> 整理时间：2026-11-06
> 项目代号：nabu-port（UniXNU / XNU 8796 移植）
> 设备：小米平板 5（nabu），骁龙 860（SM8150-AC），Adreno 640

---

## 目录

1. [当前进度总览](#1-当前进度总览)
2. [硬件事实清单](#2-硬件事实清单)
3. [启动链原理](#3-启动链原理)
4. [镜像格式与打包](#4-镜像格式与打包)
5. [关键参数（含踩坑记录）](#5-关键参数含踩坑记录)
6. [刷机完整流程](#6-刷机完整流程)
7. [排障手册](#7-排障手册)
8. [GPU 现状与下一步](#8-gpu-现状与下一步)
9. [工具清单](#9-工具清单)
10. [风险与注意事项](#10-风险与注意事项)

---

## 1. 当前进度总览

### 已经做到的

| 项 | 状态 | 说明 |
|---|---|---|
| 内核启动 | ✅ | XNU 8796.141.3 完整走完 `bsd_init` |
| 八核全开 | ✅ | `cpus=8`，8/8 CPUs initialized |
| 根分区挂载 | ✅ | HFS 卷 `IOSRoot` 挂载成功 |
| launchd 启动 | ✅ | 走出 `load_init_program` |
| 用户态运行 | ✅ | backboardd 在跑，60 Hz 提交画面 |
| 显示管线 | ✅ | AppleCLCD + IOMobileFramebuffer + IOSurface 全部注册 |
| 触摸/按键 | 🟡 | 设备注册成功，未验证实际输入 |
| 画面内容 | ❌ | 送来的是黑帧（UI 没画出来） |
| GPU 加速 | 🟡 | 时钟/供电打通；GMU 固件已拿到，装载器写好待编译 |

### 一句话总结

**系统能启动、能跑用户态、能送帧，但屏幕是黑的（UI 内容和 GPU 渲染还没通）。**

---

## 2. 硬件事实清单

### 2.1 基本参数

| 项 | 值 |
|---|---|
| 芯片 | SM8150-AC（骁龙 860） |
| GPU | Adreno 640（a640），GMU v1 |
| 屏幕 | 1600×2560，32 位色 |
| 显存地址 | `0x9c000000` |
| 显存行宽（stride） | 6400 字节 |
| 像素格式 | BGRA（写 `0xff00c000` 显示绿色） |
| DRAM 基址 | `0x80000000` |
| **内核落地地址** | **`0x100000000`（4 GB 处）** |

### 2.2 关键寄存器

| 模块 | 地址 | 说明 |
|---|---|---|
| GPUCC（GPU 时钟） | `0x02c90000` | 大小 `0x10000` |
| GMU（GPU 管理单元） | `0x02c6a000` | 大小 `0x30000` |
| GPU CX 供电轨 GDSCR | `0x02c9106c` | `0x222001`=关，`0xF8222000`=开 |
| GPU GX 供电轨 GDSCR | `0x02c9100c` | **不要用 CPU 写！见第 8 节** |
| SMMU（qsmmu-v500） | `0x02ca0000` | 有固件怪癖 |
| RPMh RSC | `0x18200000` | 电源投票通道 |

### 2.3 分区布局（实测）

| 分区 | 起始块 | 大小 |
|---|---|---|
| super | 0x0000C000 | 2 GB |
| userdata | 0x00288040 | 475,495 MiB |
| cust | 0x00240040 | 1 GB |

---

## 3. 启动链原理

### 3.1 完整链路

```
电源键
  ↓
ABL（高通引导程序，小米原厂）
  ↓ 读 boot_a / boot_b 分区
shim（我们自己的裸机加载器，188,416 字节）
  ↓ 从 ramdisk 找到 payload
payload（内核 + 设备树 + 启动参数，约 16.8 MB）
  ↓ 解开分段、复制到 4 GB 处、设置 boot_args
XNU 内核
  ↓ bsd_init → 挂载根分区 → 启动 launchd
iOS 用户态
```

### 3.2 各组件职责

| 组件 | 干什么 | 大小 |
|---|---|---|
| **shim** | 裸机程序：初始化 MMU、读设备树、解 payload、跳内核 | 188,416 字节 |
| **payload** | 打包容器：内核各段 + ADT（苹果设备树）+ 启动参数 | ~16.8 MB |
| **ADT** | 苹果格式设备树，内核靠它认硬件 | ~10-13 KB |
| **DTB** | 高通格式设备树，ABL 靠它认板子 | 715,016 字节 |

### 3.3 为什么 payload 要放 vendor_boot 分区

Android 12+ 的分区规范：

```
boot 分区     → 放内核（我们的 shim）
vendor_boot   → 放 ramdisk（我们的 payload）+ 设备树
```

**payload 放 boot 分区的 ramdisk 里内核读不到**（实测：`no NABUXNU payload`）。

---

## 4. 镜像格式与打包

### 4.1 boot 镜像格式（Android boot image v2）

```
偏移      内容
0x000     "ANDROID!" 魔数 + 头部字段
0x830     dtb 大小 + dtb 地址（v2 专有）
0x800     内核（shim）
...       ramdisk（payload）
...       dtb（真实设备树）
```

**打包参数（与原版完全一致）**：

```bash
mkbootimg.py \
  --header_version 2 \
  --kernel  shim/Image \
  --ramdisk payload.bin \
  --dtb     dtb/boot_unpacked/dtb \
  --base 0 --kernel_offset 0x8000 \
  --ramdisk_offset 0x1000000 --tags_offset 0x100 --dtb_offset 0x1f00000 \
  --pagesize 4096 \
  --os_version 17.0.0 --os_patch_level 2035-06 \
  --cmdline "console=null" \
  -o boot.img
```

### 4.2 payload 格式（NABUXNU）

```
偏移      内容
0x000     "NABUXNU\0"       魔数
0x008     u32 版本(=1), u32 段数
0x010     u64 虚拟基址      (0xfffffe0006000000)
0x018     u64 入口地址
0x020     u64 ADT 偏移, ADT 大小
0x030     u64 内核结束地址
0x038     u64 **物理基址**  (0x100000000)
0x040     u64 内存大小      (0xfcc00000)
0x048     char 启动参数[608]
0x2a8     段表（每段 32 字节：虚拟地址/大小/文件偏移/文件大小）
```

**生成命令**：

```bash
python3 tools/mkpayload.py kernel.development.nabu adt-highmem.adt payload.bin \
    --cmdline "rd=ufsroot0 ufsrw=1 rootrw=1 debug=0xc serial=3 cpus=8 keepsyms=1"
```

### 4.3 ADT 生成的唯一正确方式

```bash
python3 tools/mkadt.py out/nabu.adt --highmem
```

- `--highmem` 会把 `dram-base` 设成 0x100000000
- **不用 `--highmem` 生成的 ADT 会导致内核落到 0x80000000（错误位置），开机卡死在复制第 1 段**

---

## 5. 关键参数（含踩坑记录）

### 5.1 启动参数（cmdline）

```
rd=ufsroot0          根设备（userdata 分区）
ufsrw=1 rootrw=1     读写挂载
debug=0xc            调试输出（必须）
serial=3             串口控制台（必须，否则内核早期就停）
cpus=8               八核全开
keepsyms=1           保留符号表
```

**可选**：

```
nabulog_dump=1       回放上次启动的日志
nabudump_page=1      回放页号（1=最新）
nabudump_all=1       关闭日志过滤
nabugpuprobe=N       GPU 探测等级（1-6）
```

### 5.2 踩坑记录（每一条都踩过）

| # | 坑 | 症状 | 解法 |
|---|---|---|---|
| 1 | **内核落地地址错** | 复制内核第 1 段时整机冻死 | payload 的 `phys_base` 必须是 `0x100000000` |
| 2 | **ADT 没加 --highmem** | 同上 | `mkadt.py --highmem` |
| 3 | **AVB 校验** | 刷完回 fastboot，`slot-unbootable: yes` | `fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img` |
| 4 | **镜像格式 v2/v4** | ABL 静默拒绝，黑屏 | 刷分区用 v2 + 关 AVB 即可 |
| 5 | **payload 放错分区** | shim 报 `no NABUXNU payload` | 放 vendor_boot 的 ramdisk |
| 6 | **没有 serial=3** | 只到 `NABU EARLY 20` 一行 | 加上 serial=3 |
| 7 | **读写挂载的日志环** | 日志回放总是旧内容 | 只读挂载写不了日志环，必须 `ufsrw=1` 才有新日志 |
| 8 | **控制台不滚动** | 日志"消失"误判为死机 | 用日志环或色块标记，不要靠屏幕滚动 |
| 9 | **寄存器偏移语义** | 写成 `偏移×4` 导致总线挂死 | GPU/GMU 寄存器表里的数字就是**字节偏移** |
| 10 | **GX 供电** | 写 0x2c9100c 必冻死 | GX 由 GMU 管，CPU 不能写（见第 8 节） |

---

## 6. 刷机完整流程

### 6.1 前置条件

```
✅ 平板已解锁 BL（unlocked: yes）
✅ 电脑装了 adb / fastboot
✅ 手上有：boot.img（我们打包的）、vbmeta.img（原厂）
✅ 平板能进 fastboot（音量下 + 电源）
```

### 6.2 刷入（每次改内核都走一遍）

```bash
# 1. 进 fastboot 后确认设备
fastboot devices

# 2. 关闭 AVB 校验（只做一次，刷了别的镜像要重做）
fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img

# 3. 刷入启动镜像
fastboot flash boot_a boot.img

# 4. 切到 a 槽并重启
fastboot --set-active=a
fastboot reboot
```

### 6.3 首次部署（换 payload/换系统时才做）

```bash
# vendor_boot 放 payload + 设备树
fastboot flash vendor_boot_a vendor_boot.img

# boot 只放 shim
fastboot flash boot_a boot-shim.img
```

### 6.4 验证成功的标志

开机前 3 秒屏幕会出现：

```
NABU GPUCC: ... ENABLED
NABU CPU: requested=8 selected=8
NABU CPU: 8/8 CPUs initialized, SGII verified
NABU DT: arm-io child glc / wdt / dsp0
NABU AKS: AppleKeyStore registered
NABU SURF: IOCoreSurfaceRoot registered
NABU FB: AppleCLCD 1600x2560 stride 6400 at 0x9c000000
mig: table max ...
hfs: mounted IOSRoot on device b(1, 0)
load_init_program: attempting to load /sbin/launchd
```

**看到 `load_init_program` 且不 panic = 用户态启动成功。**

### 6.5 恢复到原厂 Android

```bash
# 原厂镜像（MIUI 包里提取）：
fastboot flash boot_a        stock/boot.img
fastboot flash vendor_boot_a stock/vendor_boot.img
fastboot flash dtbo_a        stock/dtbo.img
fastboot flash vbmeta_a      stock/vbmeta.img
fastboot --set-active=a
fastboot reboot
```

⚠️ **不要 `fastboot erase userdata` 或恢复出厂设置**——iOS 系统就装在 userdata 里。

---

## 7. 排障手册

### 7.1 看不到内核日志怎么办

**问题**：这个控制台**不会滚动**，日志打满屏幕后面的就看不见了。

**三个办法**：

**办法一：日志环回放（推荐）**

```
1. 用读写挂载启动一次（让它把日志写进 userdata 最后 4100 KiB）
2. 重启时 cmdline 加 nabulog_dump=1 nabudump_page=1
3. 开机早期会打印上次的日志
```

**办法二：shim 直接读日志环（本地工具，不用编译内核）**

```
把 shim-gx 或 shim-ring 编译出来刷进 boot_a
→ shim 会读 userdata 末尾的日志环并直接打印（不过滤）
```

**办法三：色块标记**

```
在代码关键位置画彩色横条：
  黄 = 走到某一步
  绿 = 成功
  红 = 失败
即使文字被冲掉，颜色还在
```

### 7.2 常见 panic 含义

| panic 信息 | 含义 | 解法 |
|---|---|---|
| `unexpected SIGKILL of launchd (CS_KILLED)` | 代码签名杀了进程 | 用带 cs 修复补丁的内核 |
| `[launchd_cache_loader[N]] exited` | dyld 加载共享缓存失败 | 检查系统卷完整性 |
| `ramdisk overlaps kernel memory` | payload 落地地址和 initrd 冲突 | 检查 ADT/payload 的 phys_base |
| `no HFI reply within N us` | GMU 固件没回应 | 固件/时钟/供电问题 |

### 7.3 设备无响应

```
长按电源 15 秒 → 强制关机
按住 音量下 + 电源 → 进 fastboot
```

**fastboot 一般不会丢，设备不会变砖。**

### 7.4 关键启动日志对照表

| 日志 | 说明 |
|---|---|
| `NABU EARLY NN: ...` | 早期控制台（还没进内核主流程）|
| `NABU CPU: N/N CPUs initialized` | 多核启动结果 |
| `NABU DT: arm-io child ...` | 设备树解析 |
| `NABU FB: AppleCLCD ...` | 显示驱动注册 |
| `NABU ACCEL: AGXAcceleratorG9 registered` | GPU 占位驱动注册（**stub，不是真驱动**）|
| `NABU UFS: "userdata" on LUN 0` | UFS 驱动工作 |
| `hfs: mounted IOSRoot` | 根分区挂载成功 |
| `load_init_program: ...` | 开始启动用户态 |

---

## 8. GPU 现状与下一步

### 8.1 已经打通的

| 项 | 状态 | 证据 |
|---|---|---|
| GPUCC 时钟（内核侧） | ✅ | 日志 `cbcr 0x4221 = on` |
| RPMh 电源投票 | ✅ | `transaction complete`，`cmd0-status=0x10101` |
| CX 供电轨（软件可控） | ✅ | `0x222001 → 0xF8222000` |

### 8.2 关键认知：GX 不该由 CPU 写

```
实测两次：
  CX 关闭时写 GX → 整机冻死
  CX 打开后写 GX → 仍然冻死

结论：Adreno 640 的 GX（显卡核心）电源由 GMU 固件控制，
      CPU 硬写属于非法操作，会导致总线挂死。
```

**正确流程**：CPU 只负责 → 开时钟 → 投票 → 开 CX → **加载 GMU 固件** → 由 GMU 去开 GX。

### 8.3 GMU 固件信息（已拿到）

```
文件名：a640_gmu.bin
大小：37,680 字节
来源：github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_nabu
      （proprietary/vendor/firmware/）
```

**格式**（高通块容器，每块 16 字节头）：

```c
struct block_header {
    u32 addr;    // 目标地址
    u32 size;    // 数据长度
    u32 type;
    u32 value;
    u32 data[];  // 数据
};
```

**解析结果（7 个块）**：

| # | 地址 | 大小 | 去处 |
|---|---|---|---|
| 0 | 0x000000 | 0x30 | ITCM |
| 1 | 0x000200 | 0x140 | ITCM |
| 2 | 0x000400 | 0x38bc | ITCM |
| 3 | 0x004000 | 0x3a58 | ICACHE（需要 GPU 内存）|
| 4 | 0x040000 | 0x1b20 | DTCM |
| 5 | 0x043fe0 | 0x0014 | DTCM |
| 6 | 0x057000 | 0x0308 | 其它 |

### 8.4 GMU 加载步骤（代码已写好，待编译）

```
1. 开 GPUCC 时钟（ahb / gmu / cxo）+ GCC 父时钟 + GPLL0
2. CX 供电轨上电
3. 保持 CM3_SYSRESET = 1
4. 把 ITCM/DTCM 的块写进对应寄存器
5. ICACHE_CONFIG = 1，DCACHE_CONFIG = 1
6. CM3_SYSRESET = 0（释放内核）
7. 轮询 CM3_FW_INIT_RESULT 的 bit3
8. 成功标志：日志出现 "NABU GMU: firmware ready"
```

**GMU 关键寄存器（字节偏移）**：

| 名称 | 偏移 |
|---|---|
| CM3_ITCM_START | 0x1b400 |
| CM3_DTCM_START | 0x1c400 |
| CM3_SYSRESET | 0x1f800 |
| CM3_FW_INIT_RESULT | 0x1f81c |
| CORE_FW_VERSION | 0x1d3f8 |
| ICACHE_CONFIG | 0x1f400 |
| DCACHE_CONFIG | 0x1f401 |
| HFI_QTBL_ADDR | 0x1f985 |
| HFI_CTRL_INIT | 0x1f986 |
| HOST2GMU_INTR_SET | 0x1f994 |
| GMU2HOST_INTR_INFO | 0x1f992 |

### 8.5 GPUCC 时钟寄存器

| 时钟 | 偏移 | 父时钟 |
|---|---|---|
| gpu_cc_ahb_clk | 0x1078 | gcc_gpu_cfg_ahb_clk |
| gpu_cc_cx_gmu_clk | 0x1098 | gpu_cc_gmu_clk_src |
| gpu_cc_cxo_clk | 0x109c | bi_tcxo |
| GCC gpll0 | 0x52000（GCC 基址 0x100000）| bi_tcxo |
| GCC gpu_cfg_ahb | 0x71004 | gpll0 |
| GCC gpu_memnoc_gfx | 0x7110c | gpll0 |
| GCC ddrss_gpu_axi | 0x71154 | gpll0 |

---

## 9. 工具清单

### 9.1 打包工具链

| 工具 | 作用 |
|---|---|
| `mkbootimg.py` | 组装 boot 镜像（AOSP 官方脚本）|
| `mkpayload.py` | 打包内核+ADT 成 payload |
| `mkadt.py` | 生成苹果设备树（**必须 --highmem**）|
| `dtb/boot_unpacked/dtb` | 真实设备树（715,016 字节）|
| `scripts/pack-nabu.ps1` | 一键打包（内核 → boot.img）|
| `zig` | 交叉编译器（编 shim 用）|
| `scripts/elf2bin.py` | ELF → 裸二进制 |
| `scripts/make-bootimg.py` | 自研的镜像组装器 |
| `scripts/make-vendorboot.py` | vendor_boot 组装器 |

### 9.2 一键打包命令

```powershell
.\scripts\pack-nabu.ps1 `
  -Kernel kernel.development.nabu `
  -Cmdline "rd=ufsroot0 ufsrw=1 rootrw=1 debug=0xc serial=3 cpus=8 keepsyms=1" `
  -Out boot.img
```

### 9.3 编译内核

**方式一：GitHub Actions（推荐，本地无需 Mac）**

```
仓库：3214791900-del/unixnu-nabu-build
分支：nabu-gpu-port
工作流：build-kernel-8796.yml
```

**方式二：租用云 Mac**

```bash
bash scripts/build-on-mac.sh
# 自动：拉补丁 → 拉 dxb → 打补丁 → 挑 Xcode → 编译 → 输出内核
```

**方式三：本地 Mac**

同方式二。

---

## 10. 风险与注意事项

### 10.1 绝对不要做的事

| ❌ 不要做 | 原因 |
|---|---|
| 恢复出厂设置 / `fastboot erase userdata` | **会删掉整个 iOS 系统** |
| 用 CPU 写 GX GDSCR（0x2c9100c） | 整机冻死 |
| 用不带 `--highmem` 的 ADT | 内核落到错误地址，开机冻死 |
| 读写挂载后不做备份就跑很久 | HFS 卷会累积损坏（日志有警告）|
| 在没关 AVB 的情况下刷自制镜像 | 槽位被标记 unbootable，回 fastboot |

### 10.2 已知的系统不稳定性

```
hfs_mark_inconsistent: Runtime corruption detected on IOSRoot
hfs: error truncating data fork!
```

**系统卷是非日志式 HFS，每次读写挂载都可能产生不一致。**

**建议**：
- 平时用只读挂载（`ufsrw=0 rootrw=0`）跑，只有需要写日志时才用读写
- 定期用 macOS 的 `fsck_hfs` 修复卷

### 10.3 数据安全

```
userdata 分区（475 GB）里装着整个 iOS 系统
没有备份手段（太大）
一旦损坏只能重新制作系统卷
```

**建议**：把做好的系统卷镜像留一份（如果空间允许）。

### 10.4 免责

```
本项目是实验性移植，不保证稳定性。
刷机有风险，数据可能丢失，设备可能变砖（虽然目前都能救回）。
请自行评估风险。
```

---

## 附录 A：完整文件清单

```
nabu-port/
├── repo/                          # 内核补丁仓库（116 个补丁）
│   └── xnu-8796/patches/
├── shim-src/                      # shim 源码
├── shim-gx/                       # 带 GPU 测试的 shim
├── shim-build-files/              # 原版工具链
│   ├── mkbootimg.py
│   ├── tools/mkpayload.py
│   ├── tools/mkadt.py
│   └── dtb/boot_unpacked/dtb
├── gpu-fw/                        # GPU 固件
│   └── a640_gmu.bin
├── stock/                         # 原厂镜像
│   ├── boot.img
│   ├── vendor_boot.img
│   ├── dtbo.img
│   └── vbmeta.img
├── scripts/                       # 自研脚本
│   ├── pack-nabu.ps1
│   ├── build-on-mac.sh
│   ├── build-shim.ps1
│   ├── elf2bin.py
│   ├── make-bootimg.py
│   ├── make-vendorboot.py
│   └── make-minidtb.py
└── *.img                          # 打包好的各种镜像
```

## 附录 B：常用命令速查

```bash
# 进 fastboot
长按电源 15 秒 → 音量下 + 电源

# 看设备
fastboot devices

# 刷内核
fastboot flash boot_a boot.img && fastboot reboot

# 关 AVB（刷别的镜像后要重做）
fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img

# 检查槽位状态
fastboot getvar slot-unbootable:a
fastboot getvar current-slot

# 恢复原厂
fastboot flash boot_a stock/boot.img
```

## 附录 C：术语表

| 术语 | 含义 |
|---|---|
| **ABL** | 高通引导程序（Android Bootloader）|
| **shim** | 我们自己写的裸机加载器 |
| **payload** | 打包好的内核容器 |
| **ADT** | Apple Device Tree，苹果格式设备树 |
| **DTB** | 高通格式设备树 |
| **GMU** | GPU Management Unit，GPU 的管理小处理器 |
| **HFI** | Host-Firmware Interface，主机与 GMU 的通信协议 |
| **GDSC** | 电源开关（Power Switch）|
| **CX / GX** | GPU 的两路供电：CX=子系统，GX=核心 |
| **CBCR** | 时钟分支控制寄存器 |
| **PLL** | 锁相环（时钟源）|

---

## 附录 D：GPU 时钟实测数据（2026-11-06 凌晨）

### 顺序铁律

```
❌ 先开时钟，再给 CX 上电 → GPUCC 时钟全部起不来
✅ 先给 CX 上电（0x222001 → 0xF8222000），再开时钟 → 全部成功
```

### 实测可用的时钟（从 shim 裸机代码里直接写）

| 时钟 | 寄存器 | 写入后读回 | 说明 |
|---|---|---|---|
| gcc_gpu_cfg_ahb | 0x100000+0x71004 | 0x00000001 | GPUCC 寄存器访问时钟 |
| gcc_gpu_memnoc_gfx | 0x100000+0x7100c | 0x00000221 | GMU 访问内存时钟 |
| gcc_ddrss_gpu_axi | 0x100000+0x71154 | 0x00000001 | AXI |
| gpll0 | 0x100000+0x52000 | bit0=1 | 主锁相环 |
| gpu_cc_ahb | 0x2c90000+0x1078 | 0x00000001 | |
| gpu_cc_cx_gmu | 0x2c90000+0x1098 | 0x00004221 | |
| gpu_cc_cxo | 0x2c90000+0x109c | 0x00000001 | |

读回值 **bit31 = 0 表示时钟真的在跑**；bit31 = 1 表示 CLK_OFF（没跑）。

### 检查时钟是否真的起来的代码

```c
uint32_t before = *(volatile uint32_t *)addr;
*(volatile uint32_t *)addr = (before & ~0x80000000u) | 1u;   // 清 halt 位 + 请求使能
for (int i = 0; i < 300; i++) {
    if (!(*(volatile uint32_t *)addr & 0x80000000u)) return 1;  // 成功
}
return 0;   // 失败
```

### 仍未解决的

```
GMU 寄存器写不进去（sysreset 写 1 读回 0），写 ITCM 会挂死。
候选原因：gds_hw_ctrl(0x1540) 需要切成软件控制、PLL1(0x100) 需要使能、
         或必须在完整内核环境里访问。
```

---

## 附录 E：GPU 时钟实测（2026-11-07 更新）

### 核心结论：顺序决定成败

```
❌ 先开 GPUCC 时钟，后给 CX 上电
   → 所有分支读回 0x80000001（bit31 = CLK_OFF），时钟实际没跑

✅ 先给 CX 上电（0x222001 → 0xF8222000），再开时钟
   → 读回 0x1 / 0x4221，时钟真的在跑
```

**原因**：GPUCC 的时钟分支位于 CX 电源域内，域没电时分支无法脱离 halted 状态。

### 实测数据（内核 probe=6）

| 时钟 | 寄存器 | 修复前 | 修复后 |
|---|---|---|---|
| gpu_cc_ahb | 0x1078 | 0x80000001 | **0x1** |
| gpu_cc_cx_gmu | 0x1098 | 0x80004221 | **0x4221** |
| gpu_cc_cxo | 0x109c | 0x80000001 | **0x1** |
| gcc_gpu_cfg_ahb | 0x71004 | — | 0x1 |
| gcc_gpu_memnoc | 0x7100c | — | 0x221 |
| gcc_ddrss_gpu_axi | 0x71154 | — | 0x1 |

**判断时钟是否真跑：看 bit31 是否清零**（内核只检查 bit0 会误报 "ENABLED"）。

### 仍未解决

```
GMU 的 CM3 核心：读 0x1d3f8 会挂死（内核和 shim 都一样）
→ 需要 GMU 上电序列（PLL1 使能、gds_hw_ctrl、可能的独立电源域）
GX 供电：GMU 控制，CPU 写 = 冻机
```

---

## 附录 F：编译链路（不依赖 GitHub Actions）

### 为什么不用 GitHub Actions

```
本账号 macOS 任务 3 秒被取消（runner 未分配）
换新账号、换公开仓库都一样
→ macOS 机器要求账号有有效付款方式
→ 已计量 $56.30 但无付款方式 → 直接拒绝
```

### 实际方案：AppVeyor + GitHub 中转

```
① AppVeyor（免费，开源项目）
   镜像 macos-sonoma = macOS 14.2.1 + Xcode 15.2
   配置：appveyor.yml
   脚本：scripts/build-on-mac.sh
   耗时：约 20-45 分钟

② 产物在 Cloudflare R2（国内访问不了）
   用 .github/workflows/fetch-appveyor-kernel.yml 中转：
   GitHub Linux 机器下载 → gzip → base64 → 切块 → 提交到 ci-kernel/

③ 本地取回
   通过 api.github.com 逐块下载 → 解码 → gunzip → sha256 校验
```

### 脚本里必须处理的四个坑

| 坑 | 现象 | 处理 |
|---|---|---|
| brew 挂死 | tooling 阶段卡几十分钟 | 硬超时 3 分钟 + 强杀 |
| PATH 被重写 | `gum: command not found` | 工具装到 `/usr/local/bin` |
| 工具检查 | `Invalid xnu version` / 缺工具 | jq/ninja 下二进制、gum 下 tar、xcodes 造假 |
| 版本参数 | 同上 | 导出 `MACOS_VERSION=13.5` |

---

## 附录 G：黑屏定位（当前主攻方向）

### 现象

```
内核正常启动（八核、根分区、launchd）
→ panic: launchd_cache_loader[22] exited -- exit reason namespace 7
（namespace 7 = OS_REASON_DYLD）
→ 用户态进程树倒塌
→ SpringBoard 没有机会启动
→ 屏幕黑
```

### 已排除

```
✅ 显示驱动（AppleCLCD 1600x2560 stride 6400 验证通过）
✅ 显存（0x9c000000，绿条测试通过）
✅ 送帧（backboardd 每秒 60 次）
✅ 代码签名（已修，launchd 能活）
✅ GPU（与黑屏无因果关系）
```

### 正在做的两个诊断

1. **退出原因诊断**（`zzzzzzzzzzzzzzzzzzzz-nabu-exit-reason.patch`）
   - 打印 `NABU EXIT: <名字> pid=.. ns=.. code=..`
   - 打印 `NABU EXIT DESC: <dyld 的原始错误>`

2. **文件体检**（`zzzzzzzzzzzzzzzzzzzzz-nabu-cache-probe.patch` + 生成器里的 `nabu_cache_probe`）
   - 根分区挂载后检查 5 个关键路径
   - 打印 `NABU CACHE: OK size=.. mode=..` 或 `MISS error=..`

### 可能的结论与对策

| 检查结果 | 含义 | 对策 |
|---|---|---|
| MISS | 文件不存在 | 从 IPSW 补文件 |
| OK 但 size 很小 | 文件空（制作时没拷）| 重新制作系统卷 |
| OK 但 2-3 GB | 文件在，读/映射失败 | 改 HFS 大文件支持或分块 |
| DESC 报签名 | 签名校验 | 改校验逻辑 |

---

## 附录 H：黑屏真因与点火序列（2026-11-11）

### H.1 dyld 共享缓存不在根文件系统里

iPadOS 16/17 把 dyld 共享缓存放在 **IPSW 的第二个成员**（cryptex/preboot 内容），
不在根文件系统的 `/System/Library/Caches/com.apple.dyld/` 里。

缺它的后果：`launchd_cache_loader` 加载失败（OS_REASON_DYLD）→ 用户态全灭 → 黑屏。

**处理办法**（我们已做）：
```
7z x 096-03936-078.dmg "System/Library/Caches/com.apple.dyld/*"    # 50 个文件 / 2.4 GB
guestfish: tar-in 进 HFS 根镜像
刷入 userdata
```
开机日志验证：
```
libignition: dyld_cache: opened shared cache directory: /System/Library/Caches/com.apple.dyld/
libignition: goodbye: ignition sequence complete
```

### H.2 ignition（点火）的等级机制

libignition 按 `ignition_level` 分级执行，等级不够的阶段直接跳过：

| 阶段 | 最低等级 |
|---|---|
| dyld_cache（定位并加载共享缓存）| 1 |
| preboot（挂载 /private/preboot）| 2 |
| cryptex1 sniff（探测系统 cryptex）| 2 |
| graft（嫁接 cryptex）| 3 |
| select os cryptex path | 3 |

实测三档：

| 等级 | 结果 |
|---|---|
| 0 | 全部跳过 → `library not loaded: /usr/lib/libSystem.B.dylib` |
| 5（默认）| 先跑 preboot → 无 preboot 分区（error 25）→ 点火整体失败 |
| **1** | 跳过 preboot/cryptex，dyld_cache 成功 → **点火完成** ✅ |

### H.3 KGSL 寄存器下标 vs 字节偏移（GPU 必读）

`a6xx_reg.h` 里 `A6XX_GMU_CM3_SYSRESET = 0x1F800` 是**第几个 32 位字**：

```
真实地址 = GPU 寄存器基址 + 下标 × 4
         = 0x02C00000 + 0x1F800 × 4
         = 0x02C7E000
```

按字节偏移访问 0x1D3F8 会落进未映射区 → **总线挂死**（我们踩过）。

常用地址换算（SM8150 / A640）：

| 寄存器 | 下标 | 真实地址 |
|---|---|---|
| CM3_SYSRESET | 0x1F800 | 0x02C7E000 |
| CM3_FW_INIT_RESULT | 0x1F81C | 0x02C7E070 |
| CM3_BOOT_CONFIG | 0x1F801 | 0x02C7E004 |
| CM3_CFG | 0x1F82D | 0x02C7E0B4 |
| ITCM 起始 | 0x1B400 | 0x02C6D000 |
| DTCM 起始 | 0x1C400 | 0x02C71000 |

GMU 启动成功标志：`CM3_FW_INIT_RESULT == 0xBABEFACE`。

---

## 附录 I：参考实现（已跑通桌面）

### I.1 社区移植（UniXNU 官方收录）

设备页：`https://unixnu.com/devices/models/nabu`，共 6 个仓库。
其中 `zzweiqing/UniXNU-nabu` 已达：

```
八核 + SGI IPI（130 万次零失败）
UFS 根卷（OS + SystemOS 窗口）
NT36523 触摸
GOP 帧缓冲 + A640 GPU 合成
Metal 前端（metal2vulkan + Turnip）
★ 实机演示过可交互 SpringBoard 桌面
已知问题：前几帧后偶发扫描输出卡住（补丁已打包未验证）
```

### I.2 硬件参数（他们验证过的）

```
GPU MMIO   0x02c00000    GMU 0x02c6a000    RSCC 0x02c8d000
GPU SMMU   0x02ca0000    GPUCC 0x02c90000  GCC 0x00100000
Adreno 640 v2，chip-id 0x06040001，GMEM 1 MiB
固件 a630_sqe.fw / a640_gmu.bin / a640_zap.{mdt,b02}
```

### I.3 开源组件（UniXNU 组织）

| 仓库 | 作用 |
|---|---|
| Adreno740 | 原生 XNU Adreno GPU 驱动（系列基础）|
| AdrenoMetal | Metal 前端（metal2vulkan + Turnip）|
| AdrenoFirmware | GMU 固件 + HFI 套件 |
| AdrenoPM4 | PM4 命令包编码 |
| AirNir | 着色器编译器（AIR→NIR→IR3）|
| GopFramebuffer | 显示交接 |
| ArmSmmu4K | SMMUv2 4K 页表 |

移植先例：`xVanTuring/Adreno650`（SM8250）、`Adreno610`（SM6225）——
说明 A640 也能按同法移植（同属 a6xx 家族）。

### I.4 他们的启动方式（与我们不同）

```
ESP 分区（nabu 上 /dev/block/sda31，约 334 MiB）
  ├─ rEFInd
  └─ /EFI/UniXNU/{UniXNU.efi, Drivers/DarwinBoot.efi, unixnu.toml}
       └─ Payloads/kernel.macho + .adt + .trustcache
→ 原厂 UEFI → rEFInd → UniXNU → DarwinBoot → 内核
```

写入需要 **Android + root 的 adb**（`su -c 'sh install.sh install <stage>'`）。

---

## 附录 J：复刻构建与现成文件（2026-11-11）

### J.1 构建输入（用户自备，不入库）

```
ipsw-21h16-small.zip = 从 iPadOS 17.7 (21H16, iPad7,11) IPSW 提取 4 个成员：
  kernelcache.release.ipad7c      2c395d03d21129d79f4ad9648fe30b1dd8fc62b17f180b79976604102a4678ba
  DeviceTree.j171ap.im4p          1d5ce5ee967b98df2b0017931d3a18b77add92f8902b42b12061ab5e21fd0ebb
  044-17597-018.dmg.trustcache    7640ab0933ba6a9048b6de8cf7e1e0d4806350c5eb2ccb3bc1284b79b1499e2d
  044-18090-018.dmg.trustcache    381d0eeb39949a4ed9cbca7f89ae3442fa37e9afcaaa5f1314465b43aaa46ea4

提取命令：
python3 source-ci/prepare_ipsw_input.py --ipsw <IPSW> --output ipsw-21h16-small.zip
```

IPSW 直链（苹果 CDN，国内可下，实测 20 MB/s，云端 140-200 MB/s）：
```
https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-78914/A081E8C4-D00A-4FC5-A650-A42EA1726236/iPad_10.2_17.7_21H16_Restore.ipsw
```

### J.2 构建命令（他们 CI 的核心）

```bash
git clone --no-checkout https://github.com/UniXNU/UniXNU.git unixnu
git -C unixnu fetch origin 245aca1a9ec5b730b1cad80fade295800d2981f1
git -C unixnu checkout --detach 245aca1a9ec5b730b1cad80fade295800d2981f1

export UNIXNU_IPSW=$PWD/ipsw-21h16-small.zip
python3 source-ci/prepare_source.py --upstream unixnu --device nabu-device \
        --profile nabu_bootstrap_defconfig --report report.json

brew install llvm lld mtools dtc unifdef
cd unixnu && ./unixnu defconfig nabu_bootstrap_defconfig && ./unixnu build kernel
```

**注意**：设备仓库发布的 `board.toml` 是 GPU 配置状态；若要编 bootstrap，
必须先把三处改回：`defconfig`、`archives`、`[kernel.prelink] roots`
（以及删掉 `early_security_init`），否则 `prepare_source.py` 会拒绝。

### J.3 现成文件（ready/ 目录）

| 文件 | 大小 | 用途 |
|---|---|---|
| kernel.macho | 58 MB | 他们验证过的内核 |
| bootstrap.apfs | 65 MB | 配套启动包 |
| boot-chain/UniXNU.efi | 90 KB | 启动管理器 |
| boot-chain/DarwinBoot.efi | 40 KB | 内核加载器 |
| trustcache/*.trustcache | 60 KB | 信任缓存（哈希已验）|
| kernelcache/* | 15.5 MB | iPadOS 17.7 内核缓存 + 设备树 |
| ipsw-21h16-small.zip | 15 MB | 构建输入 |

### J.4 还缺什么才能进苹果系统

```
① kernel.macho.adt（设备树）——构建时自动生成，或单独用工具生成
② iPadOS 完整系统卷（APFS，卷名必须是 nabu_os）
③ ESP 引导环境（rEFInd + UniXNU）——需要 Android + root 写入
```

### J.5 我们的两条并行路线

| 路线 | 状态 | 说明 |
|---|---|---|
| A：自己的 shim + HFS + 自编内核 | 点火完成，卡在共享缓存映射 | 自主但 GPU 是死结 |
| B：复刻 UniXNU（他们已验证）| 正在打通构建 | 有桌面先例，缺部署环境 |
