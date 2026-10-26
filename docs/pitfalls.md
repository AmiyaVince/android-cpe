# 踩坑总集

按"会浪费你多少时间"排序。每一条都是实测踩过的，不是推测。

---

## 1. `app_process` 调 `TetheringManager`

### 1.1 主线程没有 Looper

`app_process` 起的是裸 JVM 线程。不先准备 Looper，`ActivityThread` / `ContextImpl` 建 Handler 时直接抛：

```
RuntimeException: Can't create handler inside thread that has not called Looper.prepare()
```

入口第一件事：

```java
if (Looper.myLooper() == null) Looper.prepareMainLooper();
```

### 1.2 拿 Context 只能靠 `ActivityThread.systemMain()`

`currentActivityThread()` 在裸 `app_process` 里返回 `null`。正确写法：

```java
Object thread = Class.forName("android.app.ActivityThread")
        .getDeclaredMethod("systemMain").invoke(null);
Context ctx = (Context) thread.getClass()
        .getDeclaredMethod("getSystemContext").invoke(thread);
```

### 1.3 API 36 的 API 形状和记忆里的不一样

照 AOSP 源码或网上旧文章写会编译不过：

- 请求类是**嵌套**的 `TetheringManager.TetheringRequest`（不是 `android.net.TetheringRequest`）
- 回调是 `TetheringManager.StartTetheringCallback`
- 停止是 `stopTethering(TetheringRequest, Executor, StopTetheringCallback)`
- `TetheringEventCallback` 在 API 36 里只剩 `onTetheredInterfacesChanged`

### 1.4 `TETHERING_ETHERNET` 编译期拿不到

它是 `@SystemApi`，公开 SDK 的 `android.jar` 里被剥掉了，只剩 `TETHERING_WIFI` 和 `TETHERING_PERMISSION`。运行期框架里它是 public 字段——反射取真值，取不到才退回 AOSP 写死的 `5`：

```java
try { return TetheringManager.class.getField("TETHERING_ETHERNET").getInt(null); }
catch (Throwable t) { return 5; }
```

### 1.5 错误码 18 不是失败

`TETHER_ERROR_DUPLICATE_REQUEST = 18` 的意思是"已经开着"。看门狗必须把它当成功处理，否则会每 30 秒重试一次、刷满日志。

### 1.6 回调超时不等于失败

共享本来就已经开着时，状态没有变化，框架可能**根本不回调**。12 秒超时后应当用 `dumpsys ethernet` 复核实际状态，而不是判失败。

---

## 2. 以太网共享本身

### 2.1 ColorOS 的共享会被框架悄悄重置

链路抖动一次（`carrier off` → `carrier on`）后：

- `Tethering interface mode` 从 `2`(SERVER) 退回 `1`(CLIENT)
- `Tethered interface requests` 从 `1` 变 `0`
- `eth0` 的 IPv4 消失，客户端退化成 `169.254.x` link-local

**开机也不会自动开。** 这就是必须有看门狗的原因。

### 2.2 共享网段不是 AOSP 标准的 `192.168.42.x`

ColorOS 用 `10.68.92.x`，而且**每次重启会重新随机分配**（实测 `10.193.51.x` → `10.172.61.x`）。所以任何下游脚本都不能硬编码网关地址，一律走 DHCP。

### 2.3 判断共享是否生效，只看一个字段

```bash
dumpsys ethernet | grep "Tethering interface mode: 2"
```

`2` = SERVER。不要用 UI 上的开关状态或 `dumpsys tethering` 的冗长输出判断。

### 2.4 自建 NAT + dnsmasq 不能当兜底

自己给 `eth0` 配 IP、起 dnsmasq、加 MASQUERADE，**去程能通、回程走不通**——高通 IPA 硬件卸载要求 fwmark 归属，软件 NAT 绕不过去。

所以 `cpe_net` 的设计是：优先调起 ColorOS 原生共享；自建路径只在它没接管时补位（且只对部分场景有效）。

---

## 3. 硬件与驱动

### 3.1 拓展坞不接 PD 供电 → `carrier` 恒为 0

网卡枚举成功、`eth0` 创建成功、驱动绑定成功、`ip link` 显示 UP，**但 `carrier=0`**，网口灯不亮。

**所有软件层指标都"正常"，只有物理层起不来。** USB-C 单口供电不足以驱动千兆网卡 PHY，必须接拓展坞的 PD 供电口。

### 3.2 老内核不认 RTL8156

主线 `r8152` 直到 Linux 5.13 才支持 RTL8156/8156B。5.10 内核大概率不认，选 RTL8153B（USB3 千兆）更稳。

### 3.3 缺 `rtl_nic/rtl8153b-2.fw`

```
r8152: Direct firmware load for rtl_nic/rtl8153b-2.fw failed with error -2
r8152: unable to load firmware patch rtl_nic/rtl8153b-2.fw (-2)
```

没有固件也能工作，但可能是 PHY 不稳的诱因。`/vendor` 和 `/odm` 是只读 `erofs`，只能走 KernelSU 模块 overlay 到 `vendor/firmware/rtl_nic/`。

### 3.4 拓展坞占用 USB-C 口后 adb 会断

手机变成 USB 主机，USB adb 立刻断。**插拓展坞之前**先：

```bash
adb tcpip 5555
# 插上拓展坞后
adb connect <手机IP>:5555
```

实测 USB 与 TCP adb 可以并存。`adb usb` 切回。

---

## 4. 充电与电池

### 4.1 `chg_up_limit` 重启不保留

开机复位成 `0,80,0,80,2`，必须由模块开机重写。

### 4.2 ColorOS 会写回自己的值

实测见过它写 `0,90,1,90,4` / `0,80,0,80,2`。60 秒看门狗是必须的，不是保险。

### 4.3 "显示在充电但充不进去"是显示假象

唯一可信判据是 `current_now` 与电芯电压，不是状态栏图标、也不是 `status` 字段。

真旁路的特征：电芯电压纹丝不动、`current_now=0`、`ibat=0`，同时 `usb/current_now` 非零。

### 4.4 `/data/adb/cpe/` 下 `su -c` 写不进去（SELinux）

```
cp: /data/adb/cpe/tetherctl.dex: Permission denied
```

连 `cat /data/adb/cpe/net.log` 都可能被拒。**dex 必须放模块目录** `/data/adb/modules/cpe_net/`，那里 `su -c` 可写。

### 4.5 `cp A B && cp C D` 的链路陷阱

第一段失败就整条断。第二次部署时因此没更新到 `service.sh`，跑的还是旧脚本——`tether` 参数不认识，直接落进开机死循环，把 adb 命令挂死。

**部署要一行一条、逐个查 `$?`。**

---

## 5. 短信转发

### 5.1 SQLite rowid 会复用

删掉一条短信（`_id=9`）后，新短信**又拿到了 `_id=9`**，而水位线是 `last_id=9` → `_id > 9` 查不到 → 漏转。

**修法：复合游标。**

```sql
WHERE date > $last_date OR _id > $last_id ORDER BY date ASC, _id ASC
```

新短信的 `date` 一定更大，即使 id 被复用也能抓到。

### 5.2 首次解锁前读不到短信（FBE）

`/data/data/com.android.providers.telephony` 在首次解锁前不可读。判据：

```bash
dumpsys trust | grep "deviceLocked=0"
```

设了 PIN/图案的话，短信转发会一直哑到有人解锁为止。

### 5.3 日志绝不能落短信正文

验证码本身就是凭据。日志只记号码 / 长度 / 结果，`sms.conf` 权限 600。

### 5.4 Bark 用 form 编码，不用 JSON

短信正文里的引号、反斜杠、换行、中文全部交给 `curl --data-urlencode`，脚本里不需要写任何转义。

---

## 6. 电信 FTTR / 光猫（案例，非通用）

> 这一段是特定型号 + 特定 ISP 的实测记录，用于说明"降级为二层交换机"的思路，不要照抄参数。

### 6.1 Windows 的 DHCP 退避会骗人

`ipconfig /release` 后第一次 `renew` 失败、拿到 `169.254.x` 是**正常的**——Windows 按 1/2/4/8… 指数退避重试。实测第一次失败、约 7 分钟后第二次直接成功。

### 6.2 手机自己够不到光猫的管理地址

`ip route get 192.168.1.1` 会走 5G 上行（Android 策略路由优先于 main 表的直连路由）。`ip rule add` 即使 su 也被 SELinux 拒。

真正管用的写法：**显式绑定源地址**。

```bash
curl --interface 192.168.1.250 http://192.168.1.1/
```

`--interface eth0` 不管用（源地址会选成共享网段那个）。

### 6.3 光猫降级后，下游客户端够不到它的管理地址

客户端都在手机的共享网段，光猫还留在 `192.168.1.1` —— 不同网段。管理只能从手机走。

解法：给 `eth0` 挂一个同网段的地址（`cpe_net` 的 `MGMT_ALIAS`），开机自动挂、重启不丢。

### 6.4 改 LAN 配置时必须原样回填其他字段

只改 `dhcpEnbl`、其余字段（`lanIp` / `poolStart` / `poolEnd` / `subnetMask`）原样回填，否则会触发 LAN 重启、把管理连接掐断。

---

## 7. 信号测量

### 7.1 制式重选有"粘滞"

同一位置重启前后可能驻留不同制式。判定"有没有 5G 覆盖"必须多次采样，不能凭一次快照。

### 7.2 信号强度会骗人

实测某位置 RSRP 比别处好 20 dB，但制式从 NR n78 掉到 LTE B8（900 MHz），带宽潜力差一个量级。

**判据必须包含制式 + 频段，最终用速率定案。**

### 7.3 n78 对遮挡极敏感

机箱后、某些窗边，3.4 GHz 直接消失。所谓"靠窗信号好"必须加方向条件——只有朝基站那扇窗才成立。

---

## 8. 系统与 root

### 8.1 KernelSU 的 `su` "不存在"陷阱

`which su` / `ls /system/bin/su` / `su -c id` 报 `not found`，**不能用来判断有没有 root**。

KSU 只对已在管理器里授权的调用者"显露" su。未授权的调用者报 `su: inaccessible or not found`（exit 127），和"根本没有 root"一模一样。Magisk 会弹窗，KSU 不会。

正确判据只有两条：管理器首页状态、`grep kernelsu /proc/modules`。KSU 还会刻意抹掉 `/sys/module/kernelsu`，别用它判断。

### 8.2 OTA 会冲掉 root

系统更新重写 boot 分区（ramdisk 被覆盖）。第一优先事项是关掉自动更新：

```bash
pm disable-user --user 0 com.oplus.ota
```

### 8.3 多槽位设备：root 可能只在一个槽位

对比 `boot_a` / `boot_b` 的内核版本串就能看出来。若设备切到没有 root 的那个槽位启动，会进入**另一个旧系统**。

### 8.4 ColorOS 上 `adb install` 会被确认框卡死

安装确认 Activity 在锁屏时直接挂住 >180 s。改用 root 静默安装：

```bash
pm install -r -g /data/local/tmp/app.apk
```
