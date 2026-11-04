# 在 macOS 上使用 HP Laser 10x/13x、Color Laser 15x/17x 系列打印机

> 本文是 [README.md](README.md) 的中文翻译，含"使用 Colima"与"代理设置"两节。翻译：Shelly Wang。

惠普从未给 **HP Laser 10x/13x** 和 **HP Color Laser 15x/17x** 系列出过 macOS 驱动——
只有 Windows 和 Linux 版。这些打印机是"主控式"（host-based）的：它们只认 SPL-C/QPDL
语言，自己不会渲染 PostScript 或 PCL，所以 macOS 自带的通用驱动对它们完全无效。

本项目把 **HP 官方的 Linux 驱动跑在一个容器里**，而 **USB 连接仍由 macOS 直接掌管**。
装好之后，你可以像用任何普通打印机一样，从任意应用里直接打印。

已在 macOS 26.3（Apple 芯片）+ HP Color Laser 150a 上测试通过；另在 macOS 26.6.2 +
Colima + 同一台打印机上验证可用。

```
应用程序
    │
    ▼
CUPS (macOS)  ──►  cgpdftoraster  ──►  rastertospl-remote      ← CUPS 过滤器（/bin/bash）
                                              │
                                    /Users/Shared/hp-uld       ← 共享中转目录
                                              │
                                   容器内: rastertospl         ← HP Linux 驱动（arm64 原生）
                                              │
                                          SPL / QPDL
                                              │
                                    CUPS usb 后端  ──►  打印机
```

## 支持的打印机

| 系列 | 型号 | 使用的 PPD |
|---|---|---|
| HP Laser 10x | 107a, 107w, 108a, 108w | `HP_Laser_10x_Series.ppd` |
| HP Laser MFP 13x | 135a, 135w, 137fnw | `HP_Laser_MFP_13x_Series.ppd` |
| HP Color Laser 15x | 150a, 150nw | `HP_Color_Laser_15x_Series.ppd` |
| HP Color Laser MFP 17x | 178nw, 179fnw | `HP_Color_Laser_MFP_17x_Series.ppd` |

只解决打印。一体机（MFP）的扫描功能不在本项目范围内。

## 环境要求

- Apple 芯片或 Intel 芯片的 Mac
- 一个容器运行时：Docker Desktop、Colima 或 Podman——打印时必须处于运行状态
- 管理员权限（过滤器要安装到 `/Library/Printers`）

## 安装

```sh
git clone https://github.com/devanyahya/hp-color-laser-150a-macos.git
cd hp-color-laser-150a-macos
./install.sh
```

安装脚本会自动：检测已连接的打印机 → 从惠普官网（ftp.hp.com）下载 HP 官方 Linux
统一驱动 → 校验 SHA-256 checksum → 构建容器镜像 → 安装 CUPS 过滤器和 PPD →
创建打印队列 → 最后做一次不耗纸的转换自检。

常用参数：`--queue NAME`（队列名）、`--paper Letter`（纸张）、`--uri URI`（接了多台打印机时）、
`--ppd FILE.ppd`、`--no-suppressor`。详见 `./install.sh --help`。

为了让重启后还能打印，请把容器运行时设为开机自启：

- Docker Desktop：打开 *"Start Docker Desktop when you sign in"*
- Colima：运行 `brew services start colima`

```sh
./doctor.sh      # 逐层体检，报告哪一层坏了
./uninstall.sh   # 卸载：删除队列、容器、过滤器、PPD、LaunchDaemon
```

## 使用 Colima

Colima 免费好用，但有一个文档里说得不够清楚的坑：**自定义挂载会替换掉默认挂载。**
中转目录 `/Users/Shared/hp-uld` 必须在虚拟机内可见。所以如果你配置了自定义挂载
（在 `colima.yaml` 里或用 `--mount` 参数），一定要把中转目录加进列表——而且 YAML 里的
`~` 要加引号：

```sh
colima stop
colima start --mount-type virtiofs \
    --mount /Users/Shared/hp-uld:w \
    --mount "$HOME":w
```

当容器看不到中转目录时，`install.sh`（心跳检测环节）和 `doctor.sh` 都会识别出
Colima 并自动打印上述修复命令。

## 代理设置

如果你的网络访问不了惠普下载服务器或 Debian/apt 镜像，安装前导出代理变量即可，
下载和容器构建都会走代理：

```sh
export HTTPS_PROXY=http://127.0.0.1:7890
./install.sh
```

拉取 Debian 基础镜像走的是容器运行时自己的代理配置（Colima 用户要在虚拟机内的
docker 守护进程配置里设置），不走上面这两个变量。

## 真正起作用的打印选项

HP 的 PPD 里宣传的选项比驱动实际实现的多。以下结论是在 Color Laser 15x 上转换同一
页面、比对输出字节得出的：

| 选项 | 是否有效 | 说明 |
|---|---|---|
| `Quality=600x600_2` / `_1` | **有效** | Best / Normal |
| `BlackOptimization=False` | **有效** | 合成黑代替纯 K 黑，灰阶更平滑 |
| `secBrightness=0..100` | **有效** | 50 为中性，越低越暗 |
| `secContrast=0..100` | **有效** | |
| `secSaturation=0..100` | **有效** | |
| `CyanRed` / `MagentaGreen` / `YellowBlue` | **有效** | 色彩平衡，0..100 |
| `Trapping=Off/Medium/Maximum` | **有效** | 效果较小 |
| `EdgeEnhance=Off` | **有效** | `Normal` 和 `Maximum` 输出完全相同 |
| `MediaType=...` | **有效** | 设置 `@PJL SET PAPERTYPE`，改变定影温度 |
| `Screen=Normal/Enhanced/Detailed` | **无效** | 输出逐字节相同，驱动根本不读 |
| `secRGB=Standard/Vivid/Device/...` | **无效** | 输出逐字节相同 |
| `TonerSaveMode=Save` | **无效** | 输出逐字节相同 |
| `DocumentType=Photo/...` | **无效** | JCL 选项，各选项都发出空串——只有 `X-Ray` 会发 PJL |

示例：

```sh
lp -d HP_Color_Laser_150 -o BlackOptimization=False -o secBrightness=40 file.pdf
```

### 省粉：`TonerSaveMode` 是个摆设，真正有用的是这两个

PPD 里虽然有 `TonerSaveMode` 选项，但它的两个选项对应的代码串都是空的，输出逐字节
相同——在这几款机器上纯属摆设。

真正有效的设置：

| 设置 | 单页测试效果 |
|---|---|
| `ColorModel=Gray` | 发 `@PJL SET COLORMODE = MONO`，只用黑色硒鼓 —— 900 KB → 244 KB |
| `secBrightness=70`（50 为中性，越高越浅） | 整体变浅 |
| 两个一起用 | 202 KB |

彩色激光打印机省粉的大头是灰度打印：它完全不碰三个彩色硒鼓。与其在主打印队列上牺牲
质量，不如对同一台设备再加一个草稿队列：

```sh
lpadmin -p HP_150a_Draft -E -v "$(lpinfo -v | awk '/usb:/ {print $2}')" \
    -P /Library/Printers/HP-ULD/ppd/HP_Color_Laser_15x_Series.ppd \
    -o ColorModel=Gray -o secBrightness=70 -o Quality=600x600_1
```

### 评价打印质量前必读："Best" 其实是更差的选项

`Quality=600x600_2` 在 PPD 里标注为 **Best**，也是 HP 的默认值。它把中间调渲染成
粗糙的**水平线条网屏**——能看到一道道白缝，在浅色和中间调最明显，只有油墨足够浓、
线条能融合的地方才勉强能接受。

`Quality=600x600_1`（标注 **Normal**）反而平滑得多。两者发出的都是
`HWResolution [600 600]`；后缀选的是内部加网模式，不是分辨率。所以安装脚本默认把
队列设为 `600x600_1`。

```sh
lpadmin -p YOUR_QUEUE -o Quality=600x600_1 -o BlackOptimization=False
```

别用输出文件大小来判断——"Best" 的 SPL 数据量约是 "Normal" 的**两倍**，效果反而更差。
两个都打印出来，在纸上对比。

在此之上，`BlackOptimization=False` 还能让中间调再好一点点（合成 CMY 代替纯 K）。

以下结论已验证过、确实无法改变的项，列出以免重复踩坑：

- `Screen` 无论取什么值输出都逐字节相同，驱动也不报错——那条代码路径根本不读它。
- 二进制里找到的 `JCL` 前缀关键字（`JCLDocumentType`、`JCLDarkenText`）同样无效。
- 把 PPD 的 `*Emulators` 行里的 `_scms` 去掉并不能禁用 Smart CMS——它是从内部型号
  表里选的，驱动依然要求 8-bit RGB 输入，不存在由主机做加网的路径。
- `MediaType=Thick` 会通过 PJL 提高定影温度，但并不能让线条网屏融合。

## 已知限制

- **没有打印机状态回传。** 卡纸、缺纸、缺粉不会反馈到 macOS。CUPS 的 USB 后端读了
  回传通道，但没人解析 SPL 状态，所以 CUPS 只知道"数据发出去了"。
- **打印时容器必须运行。** 如果没运行，作业会立即失败并给出明确提示，而不是干等——
  过滤器会先检查心跳文件。
- **一体机不能扫描。**

## 常见问题

- **首选 `./doctor.sh`** —— 它会依次检查运行时、容器、中转目录、心跳、过滤器权限、
  USB 识别、`ippusbd` 冲突和队列状态，每一项坏了都会直接给出修复命令。
- **打印报错"conversion engine is not running"** —— 容器运行时没启动。运行
  `colima start`（或打开 Docker Desktop）即可；容器设了 `--restart unless-stopped`，
  会随运行时一起回来。
- **打印机被旧任务卡住**（数据灯狂闪、迟迟不出纸）—— 打印机内存里卡了半页数据。
  **长按打印机面板上的取消/继续键**，直到机器把残留任务清掉，再重新发送打印。
  如果频繁出现，用 `docker logs hp-uld-spl` 查看是否有转换失败的作业。

## 这个方案难在哪

有四个 macOS 的行为会悄悄废掉显而易见的实现方式，记录在此，免得后人重走弯路。

1. **cupsd 对过滤器做沙箱隔离，禁止网络访问。** 最早的版本让过滤器通过 `127.0.0.1`
   把光栅数据 POST 给容器；`curl` 在端口确实在监听的情况下 0 毫秒内以 exit 7 失败。
   所以才改用共享目录。
2. **`/bin/sh` 和 `/usr/bin/python3` 是垫片（shim）。** 两者都要经过
   `/private/var/select/…` 解析，而 `_lp` 用户无权打开它。以 `#!/bin/sh` 开头的过滤器
   会以 `Operation not permitted`（exit 126）直接死掉。必须用 `/bin/bash`。
3. **过滤器不能放在 `/usr/local`。** 沙箱只允许 `/Library/Printers` 等受祝福的驱动
   目录。
4. **过滤器里 `umask 0000` 必不可少。** `_lp` 以 0600 权限创建的文件在容器里显示为
   `-?????????`，因为 Docker 的文件共享以登录用户身份运行。作业会在那里干等。

还有两个值得知道的坑：

- **`ippusbd` 会锁死 USB 接口。** 这些打印机在*替代设置 1* 上宣告支持 IPP-over-USB
  （class 7/1, protocol 4），macOS 一插上就会启动 `/usr/libexec/ippusbd`。它根本没法
  真正使用这台打印机——"添加打印机"对话框照样找你要驱动——但它占着接口不放，队列会
  报 *"printer is offline"* 或 *"Unable to send data to printer"*。即使用 root 身份用
  libusb 也抢不回接口，所以 OpenPrinting 的 `ipp-usb` 也没用。

  杀掉进程不算修复：macOS 会注册一个**按打印机区分的 launchd 任务**
  `com.apple.print.ippusb.<品牌>.<型号>.<序列号>`，立刻把它重启，所以定时 `pkill`
  赢多输少。安装脚本会把那个任务禁用，launchd 会记住这个状态、重启后依然有效：

  ```sh
  launchctl list | awk -F'\t' '$3 ~ /^com\.apple\.print\.ippusb\./ {print $3}'
  sudo launchctl disable "system/<任务名>"
  ```

  `uninstall.sh` 会重新启用它。脚本还会装一个定时 `pkill` 的 LaunchDaemon 作为兜底，
  以防安装之后才注册新任务。
- **`lpadmin -m everywhere` 不能配合 `usb://` URI 使用。** CUPS 2.3 会把主机部分当
  网络名解析，报 `Unable to connect to "HP:0"`。`ipp2ppd` 有同样的缺陷。

## 法律声明

- 本仓库**不含任何 HP 代码**。`install.sh` 在安装时从惠普官方服务器下载 HP Linux
  统一驱动并校验 checksum。
- HP 的二进制文件和 PPD 仍受 HP 许可协议约束；安装即表示你接受 HP 驱动许可条款。
- 本项目是独立的社区项目，与 HP Inc. 没有任何隶属、认可或赞助关系。HP、HP 标识
  和 Color Laser 是 HP Inc. 的商标。
- 本仓库中的脚本以 MIT 协议开源。

## 贡献

非常欢迎其他型号用户的反馈——请注明型号、macOS 版本，并附上 `./doctor.sh` 的输出。
如果能解析 SPL 回传通道实现状态报告，将是补上最大功能缺口的关键。
