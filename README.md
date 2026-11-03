# BarMeter

一个极简的 macOS 状态栏系统监控：抬头就能看到 CPU、内存、硬盘、网络，还有当前最吃内存的 App。

- 纯 Swift + AppKit 单文件，无第三方依赖、无后台线程
- **完全不联网**：只读本机系统计数器，不上传、不收集任何数据，也不写日志
- 内存颜色跟随「内存压力」（正常 / 偏高 / 紧张），而不是只看百分比
- 默认开机自动启动，崩溃后由系统自动拉起
- 不需要任何系统权限（不用授权辅助功能、完全磁盘访问等）

---

## 快速安装（3 分钟）

### 1. 确认系统和编译工具

需要 **macOS 12 Monterey 及以上**，Apple 芯片和 Intel 都支持。

打开「终端」，先检查有没有装 Xcode 命令行工具：

```bash
xcrun --find swiftc
```

- 输出一个路径（如 `/Library/Developer/CommandLineTools/usr/bin/swiftc`）→ 已装好，跳到第 2 步。
- 报错 → 先安装，弹窗里点「安装」，等几分钟装完：

  ```bash
  xcode-select --install
  ```

  不需要装完整的 Xcode，只要命令行工具。

### 2. 下载并安装

```bash
git clone https://github.com/paxfi/BarMeter.git ~/Projects/BarMeter
cd ~/Projects/BarMeter
./build.sh
```

`git clone` 会要求登录 GitHub（仓库是 paxfi 组织私有的，需要你的账号在组织里）。看到 `✓ 完成。看一下右上角状态栏。` 就装好了。

### 3. 装完会发生什么

- 程序装在 `~/Applications/BarMeter.app`，只在你自己的账号下，不需要管理员密码。
- 右上角状态栏出现监控条，**点一下**会弹出详细菜单。
- **第一次运行会自动打开「开机自动启动」**，以后开机自己出来。不想要可以在菜单里关掉。
- 程序在本机编译和签名，所以不会弹「无法验证开发者」的提示。

---

## 状态栏显示

**详细样式（默认，约 670 点宽）**

| 区块 | 内容 |
| --- | --- |
| CPU | 最近 60 秒曲线 · 使用率 · 用户/系统占比 · 1 分钟平均负载 |
| 内存 | 曲线（按内存压力着色）· 使用率 · 已用/总量 · 交换 · 内存压力 |
| 硬盘 | 用量胶囊 · 使用率 · 剩余空间 · 读/写速度 |
| 网络 | 上下对称流量图（蓝=下载，橙=上传）· 实时速率 |
| 最吃内存 | 当前占内存最多的 App（同一 App 的子进程合并统计） |

**紧凑样式（约 140 点宽）**：CPU / MEM / SSD 三格加上下行网速。

**颜色含义**

| 颜色 | CPU | 内存 | 硬盘 |
| --- | --- | --- | --- |
| 默认色 | 70% 以下 | 内存压力正常 | 85% 以下 |
| 橙色 | 70% 起 | 内存压力偏高 | 85% 起 |
| 红色 | 90% 起 | 内存压力紧张 | 95% 起 |

内存看的是「内存压力」不是百分比：macOS 会尽量把空闲内存拿去做缓存，百分比高很正常，压力变黄变红才说明真的不够用。

## 下拉菜单

点状态栏上的监控条，菜单里有：

- **明细**：CPU 用户/系统占比、1/5/15 分钟负载；内存的 App 内存、联动内存、被压缩、已缓存文件、交换；硬盘实际可用和读写速度；网络上下行。
- **排行**：内存占用最多的 6 个 App、CPU 占用最多的 5 个 App（只统计当前用户的进程，同一 App 的子进程合并，括号里是进程数）。
- **设置**：
  - 状态栏显示：CPU / 内存 / 硬盘 / 网络 / 最吃内存的 App，各自开关（至少保留一项）
  - 状态栏样式：详细 / 紧凑
  - 刷新间隔：1 / 2 / 3 秒（默认 2 秒）
  - 开机自动启动
- 打开活动监视器、退出 BarMeter。

设置会自动保存，重启后保持。

---

## 更新

有新版本时：

```bash
cd ~/Projects/BarMeter
git pull
./build.sh
```

`build.sh` 会自动替换旧版本并重启，设置都保留。

## 卸载

1. 菜单里关掉「开机自动启动」，再点「退出 BarMeter」。
2. 删除程序和源码：

```bash
rm -rf ~/Applications/BarMeter.app ~/Projects/BarMeter
rm -f ~/Library/LaunchAgents/com.paxfi.barmeter.plist
defaults delete com.paxfi.barmeter 2>/dev/null
```

最后一行是清掉保存的设置，可以不做。

---

## 常见问题

**装完状态栏上看不到？**
多半是被刘海挡住或被系统隐藏了。14/16 寸 MacBook Pro 的内建屏有刘海，状态栏放不下时 macOS 会直接隐藏放不下的图标。办法：
- 换成紧凑样式：外接屏上点开菜单 →「状态栏样式」→「紧凑」；或者在终端运行下面这行再重启程序：
  ```bash
  defaults write com.paxfi.barmeter style compact && pkill -x BarMeter; open ~/Applications/BarMeter.app
  ```
- 按住 ⌘ 拖动状态栏图标，把 BarMeter 拖到靠右的位置。
- 在菜单「状态栏显示」里关掉不需要的项，变窄一些。

**确认程序有没有在跑：**
```bash
pgrep -x BarMeter && echo 在运行 || echo 没运行
```
没运行就 `open ~/Applications/BarMeter.app`。

**`./build.sh` 提示「没找到 Swift 编译器」？**
回到第 1 步运行 `xcode-select --install`。系统大版本升级后命令行工具偶尔会失效，重新装一次即可。

**`./build.sh` 提示 Permission denied？**
运行 `chmod +x build.sh` 再执行一次。

**网速和活动监视器对不上？**
BarMeter 只统计物理网卡（Wi-Fi、有线），不算 VPN 这类虚拟网卡，避免同一份流量算两次。开着 VPN 时数字会比活动监视器的「网络」小，属于正常。

**硬盘剩余和「关于本机」不一样？**
BarMeter 显示的是实际马上能用的空间，不含系统「可清除」的部分，所以通常比「关于本机」里的小。

**会不会耗电、占资源？**
只有一个主线程定时器，默认 2 秒采样一次，平时 CPU 占用接近 0、内存几十 MB。进程排行只在菜单打开时才完整计算。

---

## 数据来源

| 指标 | 来源 |
| --- | --- |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` |
| 内存 | `host_statistics64(HOST_VM_INFO64)`，口径同「活动监视器」：App 内存 + 联动内存 + 被压缩 |
| 内存压力 | `sysctl kern.memorystatus_vm_pressure_level` |
| 交换 | `sysctl vm.swapusage` |
| 硬盘空间 | `statfs("/")`（APFS 容器的实际可用，不含可清除空间） |
| 硬盘读写 | IOKit `IOBlockStorageDriver` 统计 |
| 网络 | `getifaddrs`，只统计 `en*` 网卡（不重复计算 VPN 虚拟网卡） |
| 进程 | `proc_pid_rusage`（`phys_footprint` 与活动监视器「内存」列一致） |

## 项目结构

| 文件 | 说明 |
| --- | --- |
| `BarMeter.swift` | 全部源码 |
| `Info.plist` | App 信息（只显示在状态栏，不出现在程序坞） |
| `build.sh` | 编译、本地签名、安装到 `~/Applications` 并启动 |

改完代码直接运行 `./build.sh` 就能看到效果。
