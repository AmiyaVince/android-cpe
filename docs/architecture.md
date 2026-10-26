# 架构与开机流程

## 目标

一台手机 24×7 插电，收 5G，通过 USB-C 拓展坞的有线网口接到全屋网络。要求：

- 开机自动出网，不需要人碰手机
- 链路抖动能自愈
- 电池不鼓包
- 手机上收到的短信能推到主力机

## 链路

```
  5G NR
    │  rmnet_data*（运营商分配动态 IP）
    ▼
┌────────────── 手机 ──────────────┐
│  MASQUERADE / FORWARD / MSS clamp │
│           │                       │
│        eth0（USB 千兆网卡）        │
│           │                       │
│      dnsmasq（仅 ColorOS 未接管时）│
└───────────┬───────────────────────┘
            │ 千兆网线
┌───────────▼───────────┐
│  光猫 / FTTR           │
│  DHCP 关闭             │
│  纯二层桥接 + AP        │
└───────────┬───────────┘
            │
        全屋终端
```

### 为什么让手机做唯一网关

备选方案是让光猫继续做路由、手机只做"上网卡"。放弃它的原因：

1. 光猫不一定支持"电口上行"（WAN 走 LAN 口）
2. 双 NAT 会破坏 UPnP、端口映射和部分游戏联机
3. 光猫的 DHCP 关掉后，全屋只有手机一家下发地址，出问题排查路径最短

代价是：手机成了单点。所以 `cpe_net` 的看门狗是必需品，不是加分项。

## 三个模块的分工

| 模块 | 触发时机 | 失败后果 |
|---|---|---|
| `cpe_control` | 开机后等 sysfs 节点就绪 | 电池长期满电，鼓包风险 |
| `cpe_net` | 开机后等 `eth0` 出现 | 全屋断网 |
| `cpe_sms` | 开机后等 FBE 解锁 | 收不到验证码 |

三者互不依赖，可以单独安装。

## cpe_net 开机流程

```
等 sys.boot_completed = 1（最多 6 分钟）
        │
等 eth0 出现（最多 10 分钟）
        │
apply()  ← 第一次
        │
┌───────┴──────── 每 30 秒 ────────┐
│ 重新读 net.conf（热加载）         │
│ find_upstream()  找有 IPv4 的 rmnet│
│ coloros_owns()?                    │
│   ├─ 否 → tether_up() 调 dex 拉起  │
│   ├─ 否 → 自己配 IP + dnsmasq      │
│   └─ 是 → 停掉自己的 dnsmasq       │
│ ip_forward = 1                     │
│ ensure_nat()  幂等加 iptables      │
└────────────────────────────────────┘
```

所有操作都是幂等的：`iptables -C` 先查再加，IP 先查再加，dnsmasq 先查 PID 再起。这样看门狗每 30 秒重跑一遍也不会累积垃圾规则。

### 两种共享模式

| 模式 | 判据 | 谁配 IP / DHCP |
|---|---|---|
| ColorOS 接管（首选） | `dumpsys ethernet` 里 `Tethering interface mode: 2` | ColorOS |
| 自建（补位） | 上面不成立 | `cpe_net` 自己 |

自建模式只对去程有效——回程会被高通 IPA 的 fwmark 归属挡住。它的存在意义是：ColorOS 共享彻底崩掉时，至少还有一半链路。

## cpe_control 的看门狗为什么是 60 秒

内核自己的 `monitor_ui_soc_to_enable_chg_up_limit` 每 ~6 秒轮询一次。模块 60 秒写入一次，足够压制 ColorOS 偶发的写回，又不会和内核状态机抢写。

配置在 `/data/adb/cpe/config.conf`，热加载：

```sh
UPPER=50    # 充到 50% 停
LOWER=45    # 掉到 45% 复充
ENABLE=1
```

## cpe_sms 的事件模型

```
mmssms.db 写入
   │  inotifyd（内核事件，几乎零成本）
   ▼
sms_watch.sh
   │  sleep 1（等 SQLite 提交）
   │  mkdir 锁（事件与兜底轮询互斥）
   ▼
content query（起 ART 虚拟机，~1 s）
   │  复合游标 (date, _id) 增量
   ▼
curl → Bark
```

兜底轮询 60 秒一次，同时兼任 inotifyd 的存活检查。失败的消息只把 `_id` 入队（不存正文），下一轮重发。
