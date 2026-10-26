# CPE 热测试方案

## 目的

手机 24h 当 CPE 跑，要确认**不加外置散热器**时热能否稳定住，以及是否会因降频影响转发性能。

## 测点

`thermal_read.sh` 采集，`thermal_log.sh` 落 CSV（`<tag>.csv`）。

| 类别 | 节点 | 说明 |
|---|---|---|
| 电芯 | `thermal_zone/battery` + `power_supply/battery/temp` | 鼓包风险的直接指标 |
| 外壳 | `shell_back` / `shell_front` / `skin-msm-therm` | 手感与机内积热 |
| CPU | `cpu-0-0`（小核）/ `cpu-1-0` / `cpu-1-3` / `cpu-1-7` | 主发热源 |
| GPU / DDR | `gpuss-0` / `ddr` | 次要热源 |
| 基带 / RF | `mdmss-0` / `pa` / `sdr0-pa` / `sdr1-pa` | 5G 连续收发的热，CPE 特有 |
| 接口 | `conn-therm` / `usb` | 拓展坞那头的温升 |
| 降频证据 | 8 核 `scaling_cur_freq` | 频率掉到远低于 `cpuinfo_max_freq` 即为热限频 |
| 负载 | eth0 `rx_bytes`/`tx_bytes`、`/proc/loadavg` | 温度必须和流量对得上才有意义 |

## 采样节奏

- **前 1 小时**：5 分钟一次，抓升温曲线
- **之后**：15 分钟一次，看稳态与波动

## 判据

| 指标 | 正常 | 偏热 | 危险 |
|---|---|---|---|
| 电芯 `battery` | ≤ 35℃ | 35~45℃ | **> 45℃** |
| 外壳 `shell_back` | ≤ 40℃ | 40~45℃ | **> 45℃**（烫手） |
| CPU 大核 `cpu-1-*` | ≤ 60℃ | 60~75℃ | **> 75℃**（多半已在降频） |
| 基带 `mdmss-0` / PA | ≤ 60℃ | 60~70℃ | > 70℃ |

**降频判定**：大核 `scaling_cur_freq` 长时间 < `cpuinfo_max_freq` 的 60%（即 < ~1.5GHz）且伴随高温 → 已被热限频。

## 情况划分

- **情况一（当前）**：不加外置散热器
- 情况二：加散热器（待测）

tag 用 `no_fan` / `with_fan`，各自一个 CSV。

## 用法

```bash
cd thermal
./thermal_log.sh no_fan      # 采一次，追加到 no_fan.csv
```
