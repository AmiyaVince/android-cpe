# android-cpe

**把一台闲置 Android 手机做成 24×7 的 5G 有线 CPE（KernelSU / Magisk 模块集）。**

Android 的「以太网网络共享」只有 UI 开关：没有 shell 命令、开机不自启、链路抖动一次就掉。这个仓库用三个模块把这条路补完——不装第三方 App、不常驻 Java 进程、不依赖厂商保活，全部走 root + 系统原生能力。

> 实测机型：一加 10 Pro（NE2210），Android 16 / ColorOS 16，KernelSU v3.3.1（LKM）。原理上适用于 Android 11+ 的 GKI 设备，但 `cpe_control` 依赖 OPPO/一加 的充电节点。

---

## 这个仓库解决什么问题

| 痛点 | 模块 | 做法 |
|---|---|---|
| 以太网共享**无法用命令行拉起**，开机不自启、掉线不恢复 | [`cpe_net`](modules/cpe_net) | `app_process` + 反射调 `TetheringManager`，编成 7 KB dex，看门狗 30 s 自检自愈 |
| 长期插电导致**电池鼓包** | [`cpe_control`](modules/cpe_control) | 写内核原生 `chg_up_limit` 状态机，45/50 % 停充，无需用户态守护进程 |
| 手机当路由器后**收不到短信**（验证码、银行通知） | [`cpe_sms`](modules/cpe_sms) | `inotifyd` 监听短信库 + 复合游标增量查询，推送到 iPhone(Bark)，4 MB 内存、~1.5 s 延迟 |

配套的 [`thermal/`](thermal) 和 [`tools/`](tools) 是热测试与诊断脚本：确认不加散热器时能不能稳住、有没有热限频。

---

## 架构

```
                    ┌──────────── 手机（唯一路由器）────────────┐
  5G NR ── rmnet_data* ── MASQUERADE ── eth0 ── USB-C ── RJ45 拓展坞
                    │        └ dnsmasq (DHCP/DNS)              │
                    │  cpe_net: 开机拉起以太网共享 + 看门狗     │
                    └────────────────────┬────────────────────┘
                                         │ 千兆网线
                               ┌─────────▼─────────┐
                               │  光猫 / FTTR       │
                               │  降级为二层交换机  │
                               │  + AP（关 DHCP）   │
                               └─────────┬─────────┘
                                         │
                                    全屋终端（DHCP 由手机下发）
```

关键设计：**让手机做全屋唯一的 DHCP/NAT 网关，光猫只做二层交换 + AP**。避免双 NAT，也不依赖光猫是否支持电口上行。细节见 [docs/architecture.md](docs/architecture.md)。

---

## 模块一览

### cpe_net —— 以太网共享自动化

Android 没有任何公开的 shell 入口能打开以太网共享：

```
cmd tethering      → No shell command implementation
cmd ethernet       → No shell command implementation
cmd connectivity   → 没有 tethering 子命令
service call       → 只支持基本类型，传不了 Parcelable
uiautomator        → 要求屏幕已解锁，开机场景直接废
```

唯一可行的是以 root 身份跑一段 Java，直接调 `TetheringManager`：

```bash
CLASSPATH=/data/adb/modules/cpe_net/tetherctl.dex \
  app_process /system/bin cpecpe.TetherCtl start   # → RESULT:STARTED
```

源码只有 200 行（[TetherCtl.java](modules/cpe_net/src/cpecpe/TetherCtl.java)），但踩过的坑不少——Looper、`systemMain()`、`@SystemApi` 常量、错误码 18，全部记在 [docs/pitfalls.md](docs/pitfalls.md)。

实测：手动停掉后自愈；**重启后 28 秒自动恢复共享**，全程不碰手机。

### cpe_control —— 限充 / 旁路供电

```
/sys/devices/virtual/oplus_chg/common/chg_up_limit
格式：enable,upper,force,lower,callname     →  1,50,1,45,2
```

写入后由**内核自己的状态机**每 ~6 s 轮询：到 50 % 停充、掉到 45 % 复充，不需要用户态守护进程。模块只负责两件事：开机重写（重启不保留）+ 60 s 看门狗压制 ColorOS 的写回。

50 % 时实测电芯电压 3.924 V 纹丝不动、`current_now=0`、`ibat=0`，同时 `usb/current_now=375 mA`——**充电器直供主板、电池隔离在回路外，既不充也不放**，天然是 UPS。判据是 `current_now` 和电芯电压，不是状态栏图标。

### cpe_sms —— 短信转发

```
inotifyd 盯 mmssms.db
   ↓
sms_watch.sh（mkdir 锁）
   ↓
content query --where "date > $last_date OR _id > $last_id"
   ↓
curl --data-urlencode POST https://api.day.app/push
```

对比三种形态的实测成本：

| 形态 | 常驻内存 | 空闲 CPU | 延迟 |
|---|---|---|---|
| 纯轮询 10 s | 0 | 2.5 % 单核 | ≤11 s |
| **inotifyd + 60 s 兜底（采用）** | **4 MB / 1 线程** | **0.4 % 单核** | **~1.5 s** |
| 常驻 Java（ContentObserver） | 78.5 MB PSS | ≈0 | <0.5 s |

关键成本：`content query` 每次要起一个 ART 虚拟机（1.07 s 墙钟），所以事件触发远比轮询划算。

> 水位线必须用 `(date, _id)` 复合游标。SQLite 的 rowid 会复用已删除的最大 id，只用 `_id` 会漏转——这个坑踩过，见 [docs/pitfalls.md](docs/pitfalls.md)。

---

## 快速开始

### 前置条件

- 已 root 的 Android 11+ 设备（KernelSU 或 Magisk）
- USB-C 拓展坞 + **带 PD 供电口**（这是最容易踩的硬件坑，见下）
- 一个支持 USB3 的千兆网卡（RTL8153 / AX88179 等，内核需带驱动）

### 安装

```bash
# 三个模块分别是一个标准的 KernelSU/Magisk 模块目录
adb push modules/cpe_net     /data/local/tmp/
adb shell su -c 'cp -r /data/local/tmp/cpe_net /data/adb/modules/ && chmod 755 /data/adb/modules/cpe_net/*.sh'

# 配置
adb shell su -c 'mkdir -p /data/adb/cpe'
adb shell su -c 'cp /data/adb/modules/cpe_net/net.conf.example /data/adb/cpe/net.conf'
adb shell su -c 'cp /data/adb/modules/cpe_sms/sms.conf.example /data/adb/cpe/sms.conf'
# 编辑 sms.conf 填 BARK_KEY

adb reboot
```

重启后验证：

```bash
adb shell su -c 'sh /data/adb/modules/cpe_net/service.sh status'
adb shell su -c 'sh /data/adb/modules/cpe_sms/service.sh status'
```

### 重新编译 tetherctl.dex

仓库里带了编译好的 dex。要改源码的话：

```bash
# 需要 JDK 8+、Android SDK 的 android.jar 和 d8
export ANDROID_JAR=/path/to/android-36/android.jar
export D8_JAR=/path/to/build-tools/30.0.3/lib/d8.jar
./modules/cpe_net/build.sh
```

---

## ⚠️ 硬件坑：拓展坞必须接 PD 供电

不接供电时，网卡枚举成功、`eth0` 创建成功、驱动绑定成功，**但 `carrier` 永远是 0**，网口灯不亮。

原因：USB-C 单口供电不足以驱动千兆网卡的 PHY。接上 PD 供电线后 `carrier` 立刻变 1。

这个坑极具迷惑性——所有软件层指标都"正常"，只有物理层起不来。

---

## 已知限制

- **`cpe_control` 是 OPPO/一加 专属**：`oplus_chg` 节点不存在于原生 Android。其他厂商请参考 ACC 的 `charge_control_limit` 接口。
- **`cpe_net` 的纯自定义 NAT 路径不可用作兜底**：自己配 IP + dnsmasq + NAT 时，回程流量走不通（高通 IPA 硬件卸载要求 fwmark 归属）。所以模块的核心是调起 ColorOS 原生共享，自建路径只在前者未接管时补位。
- **重启后共享网段会变**（ColorOS 重新随机分配），客户端必须走 DHCP，不能用固定 IP 脚本硬编码网关。
- **`cpe_sms` 抓不到 RCS / 5G 消息**：它们不进 `content://sms`。
- **首次解锁前读不到短信**：FBE 加密，CE 存储不可用。关掉锁屏密码（或开机后解锁一次）即可。
- 本仓库**不包含任何引导分区镜像**。备份与恢复方法见 [docs/field-notes.md](docs/field-notes.md)，请务必在动手前自行备份。

---

## 目录结构

```
modules/
  cpe_net/          以太网共享自动化（含 TetherCtl.java 源码与 dex）
  cpe_control/      限充 / 放电控制器
  cpe_sms/          短信 → Bark 转发
tools/              诊断脚本（dnsmasq / 租约 / 信号采样）
thermal/            热测试方案与采样脚本
docs/
  architecture.md   链路设计与开机流程
  pitfalls.md       踩坑总集（本仓库最值钱的部分）
  field-notes.md    实测方法论：选点、热判据、旁路供电
```

---

## 安全提醒

- 本仓库的脚本会写 `iptables`、`sysfs` 和 `/data/adb`。**先在能救砖的设备上试**。
- `discharge.sh` 会把 USB 输入限流设成 0 强制放电，虽然带三重熔断（目标电量 / 下限 / 超时），但**不要在有重要事务的机器上跑**。
- 不要盲目刷入 `boot` 分区。作者的备份镜像没有随仓库分发。

## License

MIT。第三方固件（如 `rtl_nic/rtl8153b-2.fw`）不包含在仓库内，请从 [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git) 获取并遵守其许可。
