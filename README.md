# Wi-Fi 已连接但无法上网：ARP 表为空时的分层排查

> 电脑连手机热点显示「已连接」，但无 Internet；DHCP 能拿到地址，ARP 表却是空的。
> 本文只记录实测数据与由数据直接得出的推断，未经验证的内容会明确标注。

中文版：[电脑连手机热点显示「已连接」却无法上网：ARP 表为空时的排查记录](https://blog.csdn.net/2401_88602546/article/details/168970765)

## English Summary

A Windows 11 laptop joined an Android phone hotspot and showed "Connected, no Internet".

Measured facts: the client received a DHCP lease (192.168.96.9/24), but the interface's ARP table had **no entries at all** — not even the gateway — and the gateway did not respond to ping. `ReceivedUnicastPackets` was 16, versus 441 in normal operation.

Reasoning: DHCP in Android tethering is served over broadcast, which arrived; ARP replies are unicast, which did not. In WPA2-Personal these are protected by different keys (GTK vs PTK), so the pattern is consistent with a 4-way handshake that completed but produced a mismatched PTK.

Verified fix: deleting the saved Wi-Fi profile and re-pairing restored connectivity immediately — ARP resolved, gateway reachable, 0% loss, HTTP 200.

What remains **unverified**: the exact cause of the PTK mismatch (client-side cached state vs. a stale STA entry on the AP), and why the fault appeared at that particular time. Deleting and re-creating the profile is the only remedy confirmed in this incident.

---

## 目录

- [1. 现象](#1-现象)
- [2. 环境](#2-环境)
- [3. 故障状态下的实测数据](#3-故障状态下的实测数据)
- [4. 由数据得出的推断](#4-由数据得出的推断)
- [5. 修复与验证](#5-修复与验证)
- [6. 成因的两种可能（均未验证）](#6-成因的两种可能均未验证)
- [7. 排查中做过但无效的操作](#7-排查中做过但无效的操作)
- [8. 另一件独立的事：第一跳 30% 丢包](#8-另一件独立的事第一跳-30-丢包)
- [9. 未能确定的问题](#9-未能确定的问题)
- [10. 可复用的诊断清单](#10-可复用的诊断清单)
- [11. 为什么通用方案对这次无效](#11-为什么通用方案对这次无效)
- [12. 结论](#12-结论)
- [13. 脚本](#13-脚本)

---

## 1. 现象

- 系统显示「已连接」，同时标注「无法访问 Internet」；
- 手机热点界面显示「没有设备连接」，或连接/断开来回跳；
- 无法打开网页，ping 不通任何地址；
- 断开重连多次，结果相同；
- 同一热点连接另一台电脑正常；
- 用另一部不同品牌的手机开热点，同一台笔记本同样失败。

手机侧自检：手机用移动数据上网正常，未设置流量限制或设备白名单。

## 2. 环境

| 项目 | 实测值 |
|---|---|
| 系统 | Windows 11 |
| 无线网卡 | Intel Wi-Fi 6 AX201 160MHz |
| 驱动 | 22.250.10.1（2023-08-15，`oem67.inf`） |
| 手机热点 | OPPO，5GHz / 信道 149 / WPA2-Personal / CCMP |
| 另一网络 | 校园网 GiWiFi，5GHz / 信道 161 / 认证 Open、加密 None |

## 3. 故障状态下的实测数据

### 3.1 地址分配成功，网关不可达

```
WLAN IPv4     : 192.168.96.9/24    PrefixOrigin=Dhcp
默认网关      : 192.168.96.146
DHCP 状态     : Enabled
网关 ping     : 全部超时
```

地址由 DHCP 分配，说明 DHCP 交互完成过。

### 3.2 ARP 表为空，单播计数异常低

```
arp -a（该接口）       : 无任何动态邻居记录，连网关条目都没有
ReceivedUnicastPackets : 16
ReceivedPacketErrors   : 0
```

同一网卡正常工作时 `ReceivedUnicastPackets` 为 441。

### 3.3 事件日志中握手次数异常

`Microsoft-Windows-WLAN-AutoConfig/Operational`，故障当天：

```
8001  成功连接             29 次
11010 安全功能启动         50 次     此前各日 1-12 次
11004 安全功能停止         49 次
8003  断开                 23 次     其中 7 次为「网络被驱动程序断开连接」
```

按小时分布：08、09、10 点各 1、1、2 次；12 点 37 次；13 点 23 次。12-13 点的峰值与当时反复调试重连的时间段重合，属于排查动作造成，不是故障本身。

### 3.4 两次记录中的 BSSID 不同

```
故障时：BSSID = a2:23:6e:48:24:2b
恢复后：BSSID = a6:ca:db:b5:f5:65
```

两者第一字节都置了本地管理位（bit 1），属于本地生成的地址，非厂商固定分配。

## 4. 由数据得出的推断

把 3.1 与 3.2 组合：

- DHCP 成功，说明**广播帧**能正常收发——客户端尚无 IP 时，安卓热点的 DHCP OFFER/ACK 以广播形式发出；
- ARP 应答是**单播**帧，而 ARP 表始终为空，说明单播帧未被成功接收。

WPA2-Personal 中两类帧使用不同密钥，这是协议规定：

| 帧类型 | 密钥 |
|---|---|
| 广播 / 多播 | GTK（组临时密钥），握手后由 AP 下发 |
| 单播 | PTK（成对临时密钥），握手时双方各自派生 |

**推断**：4 次握手流程完成（否则拿不到 DHCP），但双方派生的 PTK 不一致，单播帧解密失败被丢弃。这能同时解释「有 IP」与「完全无法通信」两个看似矛盾的事实。

**该推断未被直接验证**。验证需要抓取空口帧并比对加解密结果，本次未做。

## 5. 修复与验证

```powershell
netsh wlan show profiles
netsh wlan delete profile name="奕 悟"
```

删除后在系统 Wi-Fi 列表重新连接、重新输入密码。修复后的实测结果：

```
网关 ping      : 来自 192.168.96.146 的回复，13ms，TTL=64
ARP 表         : 192.168.96.146 -> a6-ca-db-b5-f5-65   动态
ReceivedUnicastPackets : 441
网关丢包       : 0%（20 包），3-10ms
公网 223.5.5.5 : 0%（6 包），26-98ms
DNS            : baidu 235ms，qq 18ms
HTTP           : baidu 200，qq 200
```

**可以确定**：本次故障中，删除并重建无线配置后故障消失，重建前后各项指标同步从异常恢复为正常。

## 6. 成因的两种可能（均未验证）

PTK 不一致可能来自两侧中任意一侧，以下均只是可能，本次没有证据区分：

**可能一：客户端侧保存的安全状态与 AP 当前参数不一致。** Windows 无线配置会保存与安全相关的状态。本机该配置创建于约三个月前，期间经历多次断连与手机重启。

**可能二：AP 侧残留了该 MAC 的旧密钥。** 若手机端在客户端快速重连时保留旧条目，可能仍以旧 PTK 加密发往该 MAC 的单播帧。广播帧使用 GTK，不受影响。

判定二者需要抓取空口帧。Windows 平台的 Intel 驱动通常不提供监听模式，本次未做。

## 7. 排查中做过但无效的操作

| 操作 | 执行后的实测结果 |
|---|---|
| 重启电脑、重启手机 | 故障依旧 |
| 关闭热点「自动连接」 | 校园网丢包 30% → 17.5%，热点故障依旧 |
| `PnPCapabilities=24`（禁止网卡省电关闭） | 故障依旧 |
| MIMO 节能模式：自动 SMPS → 无 SMPS | 校园网丢包归零，热点故障依旧 |
| 漫游主动性：3.中间 → 1.最低值 | 同上 |
| NlaSvc 设为自动并启动 | 故障依旧 |
| 停止腾讯 ACE 反作弊驱动 `ACE-BOOT` | 故障依旧 |
| 解绑 VMware Bridge Protocol | 故障依旧 |
| `IEEE11nMode`：802.11ax → 802.11ac | 未改变结果 |

## 8. 另一件独立的事：第一跳 30% 丢包

同一天，这台机器连校园网时，到**第一跳网关（2ms）** 测得 30% 丢包：

```
发送 60 包，收到 42 包，丢 18 包（30%）
丢包序号: 6,7  14,15  20,21,22  25  32,33  36,37  41,42  48,49  55,56
丢包间隔: 1,7,1,5,1,1,3,7,1,3,1,4,1,6,1,6,1
```

丢包成对出现，间隔约 5-8 个包。到第一跳即丢包，说明问题在无线链路这一段，与上游无关。

修改以下两项网卡高级属性：

```powershell
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword MIMOPowerSaveMode -RegistryValue 3
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword RoamAggressiveness -RegistryValue 0
```

| 属性 | 原值 | 新值 |
|---|---|---|
| `MIMOPowerSaveMode` | 自动 SMPS | 无 SMPS |
| `RoamAggressiveness` | 3. 中间 | 1. 最低值 |

修改后连续三次复测均为 **0% 丢包**。

**注意**：两项同时修改，**无法确定是哪一项起作用**，也无法排除当时环境自行恢复。未做单项对照实验。

## 9. 未能确定的问题

1. **PTK 不一致的确切成因** —— 需空口抓包，本次未做。
2. **为什么在该时间点出现** —— 故障当天 09:52 首次切换到热点，10:17 出现「网络被驱动程序断开连接」，此后持续失败；但把校园网与热点来回切换三次的对照实验**未复现故障**，因此无法说明触发条件。
3. **为什么多人同时遇到** —— 仅有单台设备的完整数据。他人是否同一机制，需其提供相同观测（ARP 表是否为空、单播计数是否异常）才能判断，仅凭「热点连不上」这一现象无法归类。

## 10. 可复用的诊断清单

```powershell
# 1 链路状态：是否关联，协商的协议/频段/速率
netsh wlan show interfaces

# 2 地址来源：DHCP 租约还是 169.254 自动地址
Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4
Get-NetIPInterface -InterfaceAlias WLAN -AddressFamily IPv4 | Select-Object Dhcp

# 3 默认路由与网关
Get-NetRoute -DestinationPrefix "0.0.0.0/0"

# 4 ARP 表：是否解析出网关
arp -a

# 5 单播收发计数：与正常状态对比
Get-NetAdapterStatistics -Name WLAN | Select-Object ReceivedUnicastPackets, ReceivedPacketErrors

# 6 握手与断开历史
Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 200 |
    Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5

# 7 断开原因
Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 100 |
    Where-Object Id -eq 8003 | Select-Object TimeCreated, Message
```

判读：

| 观测组合 | 指向 |
|---|---|
| 有 IP、网关不通、ARP 表空、单播计数极低 | 单播不通，优先查加密/密钥层（本文场景） |
| 有 IP、网关通、公网不通 | 上行或路由问题 |
| 拿到 169.254 地址 | DHCP 未完成，问题在关联或 DHCP 之前 |
| 第一跳丢包且呈周期性 | 查网卡省电、节能模式、后台扫描 |

## 11. 为什么通用方案对这次无效

搜「电脑连不上手机热点」，主流方案是重启网卡、忘记网络重连、更新驱动、关闭防火墙、重置网络。

这些方案对本次故障无效，因为它们没有区分故障发生在哪一层。本次观测把范围限定得比较窄：

| 观测 | 可排除的可能 |
|---|---|
| 能拿到 DHCP 地址 | 关联失败、DHCP 服务异常 |
| ARP 表空、网关不通 | DNS、防火墙、路由、代理 |
| 广播能收、单播收不到 | 信号弱、干扰、IP 冲突 |
| 换手机换热点均失败、同一热点换电脑正常 | 手机侧问题 |

缺少「广播能收、单播收不到」这个区分，排查容易停在「重启网卡、换驱动」上。

## 12. 结论

1. 「已连接但无法上网」需要先定位到具体层，不能直接归因于驱动或信号。
2. 本次观测到的组合是：DHCP 成功、ARP 表为空、单播计数极低（16 vs 441）。这组数据指向单播帧未被成功接收，协议上对应 PTK 层面。
3. 本次故障中，**删除并重建无线配置后立即恢复正常**，各项指标同步恢复。这是唯一验证有效的手段。
4. PTK 不一致的成因、以及为什么在该时间点出现，本文**没有结论**，需抓包与更多样本。
5. 第一跳 30% 周期性丢包是另一独立现象，修改 MIMO 节能模式与漫游主动性后归零，但两项同时改动，**无法区分是哪一项起作用**。

## 13. 脚本

仓库内附 `wifi_hotspot_tool.ps1`，封装了上述检查项与常用操作：

```powershell
# 只读诊断：关联、地址、网关、ARP、卸载设置
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -State

# 故障现场快照（已连接但无 Internet 时运行）
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Hotspot

# 丢包基线测试：40 包到网关，输出丢包序号与间隔特征
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Baseline

# 应用低风险修改：禁止网卡省电、MIMO 无 SMPS、漫游最低、启动 NlaSvc
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Fix

# 重置网络栈：解绑 VMware 桥接、winsock/ip reset、重载网卡
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Reset

# 删除指定无线配置
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Forget "SSID名"
```

脚本为纯 ASCII 源码，兼容 Windows PowerShell 5.1 与 PowerShell 7，避免无 BOM 的 UTF-8 脚本在 5.1 下出现解析错误。修改类操作需要管理员权限。

## 参考

- [netsh wlan 命令参考](https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-wlan)
- [IEEE 802.11i：RSNA 密钥层次（PMK / PTK / GTK）](https://en.wikipedia.org/wiki/IEEE_802.11i-2004)
- [Intel Wi-Fi 6 AX201 驱动下载](https://www.intel.com/content/www/us/en/download/19351/intel-wireless-wi-fi-drivers-for-windows-10-and-windows-11.html)

## 相关链接

- 中文版（CSDN）：[电脑连手机热点显示「已连接」却无法上网：ARP 表为空时的排查记录](https://blog.csdn.net/2401_88602546/article/details/168970765)
- 另一篇排查记录：[GitHub 2FA 配置说明（面向中国大陆用户）](https://github.com/ihadimh/github-2fa-guide)

## License

[MIT](LICENSE)
