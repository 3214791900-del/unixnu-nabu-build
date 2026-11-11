# ready/ —— 进 iPadOS 所需的现成文件

整理时间：2026-11-11
来源：mytiantian001 / zzweiqing 的 nabu 移植（已验证能进桌面）

---

## 这些文件是干什么的

```
平板启动链（从开机到苹果桌面）：

  ABL（高通引导）
    ↓
  ESP 分区里的 rEFInd（引导器）
    ↓
  UniXNU.efi（菜单 + 内核加载管理）
    ↓
  DarwinBoot.efi（把内核搬进内存、准备启动参数）
    ↓
  kernel.macho（苹果内核，带 A640 GPU 驱动）
    + bootstrap.apfs（启动包）
    + kernel.macho.adt（设备树，还缺）
    + kernel.macho.trustcache（信任缓存，见下）
    ↓
  iPadOS 系统卷（在 UFS 窗口里）
    ↓
  SpringBoard 桌面
```

---

## 文件清单

### 核心（必需）

| 文件 | 大小 | 说明 |
|---|---|---|
| `kernel.macho` | 58 MB | ★ 已验证能进桌面的内核（XNU 8796.121.2，带 APFS + A640 GPU + 触摸）|
| `bootstrap.apfs` | 65 MB | ★ 配套启动包（含 GPU 用户态、霍尔锁屏库）|
| `ipsw-21h16-small.zip` | 15 MB | ★ 构建输入（4 个文件，哈希已验）|

### 启动链（装到 ESP）

| 文件 | 大小 | 装到哪 |
|---|---|---|
| `boot-chain/UniXNU.efi` | 90 KB | `\EFI\UniXNU\UniXNU.efi` |
| `boot-chain/DarwinBoot.efi` | 40 KB | `\EFI\UniXNU\Drivers\DarwinBoot.efi` |
| `boot-chain/unixnu.hall03.toml` | 1 KB | 改名 `unixnu.toml` 放 `\EFI\UniXNU\` |

### 信任缓存（内核用）

| 文件 | 大小 | 说明 |
|---|---|---|
| `trustcache/044-17597-018.dmg.trustcache` | 58 KB | 系统卷信任列表 |
| `trustcache/044-18090-018.dmg.trustcache` | 1.8 KB | cryptex 信任列表 |

放哪：和 `kernel.macho` 同目录，命名 `kernel.macho.trustcache`（两者合并）

### 系统参考（不直接用）

| 文件 | 大小 | 说明 |
|---|---|---|
| `kernelcache/kernelcache.release.ipad7c` | 15.5 MB | iPadOS 17.7 的原版内核（参考/对比用）|
| `kernelcache/DeviceTree.j171ap.im4p` | 33 KB | 原版设备树（参考 ADT 结构）|

---

## 还缺什么才能启动

### ① kernel.macho.adt（设备树）—— 必须

```
这是"把本机硬件告诉内核"的文件
每台设备不同（含芯片 ID、内存布局、帧缓冲地址）

获取方式：
  A. 等我们的 UniXNU 编译产出（会自动生成）
  B. 用 UniXNU 的 payload 工具从 board.toml 生成
```

### ② iPadOS 17.7 完整系统卷 —— 必须

```
现在只有内核缓存（15 MB），没有系统本体（约 5-8 GB）
要从 IPSW 恢复出系统卷，写进平板的 UFS 窗口
```

### ③ ESP 引导环境 —— 必须

```
平板要有：
  □ ESP 分区（334 MB，/dev/block/sda31）
  □ rEFInd（引导器）
  □ 上面 3 个启动链文件
写入需要 Android + root 的 adb
```

---

## 怎么检查这些文件是真的

```powershell
# trustcache 和内核缓存的哈希
Get-FileHash ready\trustcache\*.trustcache -Algorithm SHA256

# 应该匹配 board.toml 里的值：
# 044-17597: 7640ab0933ba6a9048b6de8cf7e1e0d4806350c5eb2ccb3bc1284b79b1499e2d
# 044-18090: 381d0eeb39949a4ed9cbca7f89ae3442fa37e9afcaaa5f1314465b43aaa46ea4
```

---

## 附：他们的启动参数（unixnu.hall03.toml 里）

```
-v keepsyms=1 debug=0x14e cpus=8 small_cores_after=0 serial=0
fb_hz=120 fb_ca_hz=120 nabu-gpu-delay=0 nabu-storage=1
nabu-bootstrap=1 nabu-data=1 nabu-native-apfs=1
rd=md0 root_apfs=nabu_os nabu-log-slot=1 nabu-setup-compat=1
nabu-touch=1 nabu-buttons=1 nabu-input=1 nabu-hall=1
nabu-wireless=5 nabu-bt-transport=1 nabu-adsp=1 nabu-gpu=1
nabu-usb-native=1 nabu-local-activation=1
```

关键：`root_apfs=nabu_os` —— 系统卷必须叫 `nabu_os`，且是 **APFS** 格式。
